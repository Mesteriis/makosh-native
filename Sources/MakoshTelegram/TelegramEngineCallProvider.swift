import Foundation
import TelegramCore
import SwiftSignalKit

@MainActor final class TelegramEngineCallProvider: TelegramCallProvider {
    private let engine: any TelegramCallEngine
    private let proxy: @MainActor () throws -> TelegramProxyServer?
    private let media: any TelegramCallMediaFactory
    private var declining: [UUID: TelegramCallSignalRequest] = [:]
    var accountID: Int64 { engine.accountID }
    init(engine: any TelegramCallEngine, proxy: @escaping @MainActor () throws -> TelegramProxyServer?, media: any TelegramCallMediaFactory) {
        self.engine = engine; self.proxy = proxy; self.media = media
    }
    isolated deinit { for request in declining.values { request.cancel() } }
    func loadPeer(_ id: Int64, receive: @escaping @MainActor (Result<TelegramCallPeer, TelegramCallError>) -> Void) -> any TelegramCallRequest {
        let request = TelegramCallSignalRequest(); request.once(engine.peer(id), receive: receive); return request
    }
    func observeIncoming(receive: @escaping @MainActor (Result<[TelegramIncomingCall], TelegramCallError>) -> Void) -> any TelegramCallRequest {
        let request = TelegramCallSignalRequest()
        request.disposable.add((engine.incoming() |> deliverOnMainQueue).start(next: { [weak request, weak self] values in
            MainActor.assumeIsolated {
                guard request?.stopped == false else { return }
                for id in self?.declining.keys.map({ $0 }) ?? [] where !values.contains(where: { $0.id == id }) { self?.declining.removeValue(forKey: id)?.cancel() }
                receive(.success(values))
            }
        }, error: { [weak request] error in MainActor.assumeIsolated { if request?.stopped == false { receive(.failure(error)) } } }))
        return request
    }
    func startOutgoing(basis: TelegramCallPeer, video: Bool, callID: UUID, receive: @escaping @MainActor (TelegramCallEvent) -> Bool) -> any TelegramCallLease {
        let lease = EngineCallLease(engine: engine, proxy: proxy, factory: media, callID: callID, outgoing: true, video: video, receive: receive)
        lease.startOutgoing(basis); return lease
    }
    func accept(incoming: TelegramIncomingCall, video: Bool, receive: @escaping @MainActor (TelegramCallEvent) -> Bool) -> any TelegramCallLease {
        let lease = EngineCallLease(engine: engine, proxy: proxy, factory: media, callID: incoming.id, outgoing: false, video: video, receive: receive)
        lease.startIncoming(incoming); return lease
    }
    func decline(incoming: TelegramIncomingCall) {
        guard incoming.isValid, incoming.accountID == accountID, declining[incoming.id] == nil else { return }
        let request = TelegramCallSignalRequest(); declining[incoming.id] = request
        request.once(engine.incoming()) { [weak self, weak request] result in
            guard let self, request?.stopped == false else { return }
            guard case let .success(values) = result, values.contains(incoming) else { self.declining.removeValue(forKey: incoming.id)?.cancel(); return }
            self.engine.drop(callID: incoming.id, reason: .busy)
        }
    }
}
@MainActor private final class EngineCallLease: TelegramCallLease {
    private let engine: any TelegramCallEngine
    private let proxy: @MainActor () throws -> TelegramProxyServer?
    private let factory: any TelegramCallMediaFactory
    private let callID: UUID, outgoing: Bool, initialVideo: Bool
    private let receive: @MainActor (TelegramCallEvent) -> Bool
    private let reads = TelegramCallSignalRequest(), observations = DisposableSet()
    private var signaling: (any TelegramCallRequest)?
    private var launch: Task<Void, Never>?, proxyWatch: Task<Void, Never>?
    private var proxyBasis: TelegramProxyServer?, configuration: TelegramCallMediaConfiguration?
    private var media: TelegramCallMediaSession?
    private var pending: [Data] = [], pendingBytes = 0
    private var committed = false, stopped = false, released = false, pendingMediaStart = false
    private var videoPossible = false, videoDesired: Bool
    private var reason = DropCallReason.hangUp
    private var completions: [@MainActor () -> Void] = []
    private var retirement: EngineCallLease?
    init(engine: any TelegramCallEngine, proxy: @escaping @MainActor () throws -> TelegramProxyServer?, factory: any TelegramCallMediaFactory,
         callID: UUID, outgoing: Bool, video: Bool, receive: @escaping @MainActor (TelegramCallEvent) -> Bool) {
        self.engine = engine; self.proxy = proxy; self.factory = factory; self.callID = callID
        self.outgoing = outgoing; self.initialVideo = video; self.videoDesired = video; self.receive = receive
    }
    isolated deinit {
        launch?.cancel(); proxyWatch?.cancel(); reads.cancel(); observations.dispose(); signaling?.cancel()
        if committed && !stopped { engine.drop(callID: callID, reason: .hangUp) }
        media?.stop(completed: {})
    }
    func startOutgoing(_ basis: TelegramCallPeer) {
        launch = Task { [weak self] in
            guard let self, !self.stopped else { return }
            guard basis.isValid, basis.accountID == self.engine.accountID, basis.canVoice, !self.initialVideo || basis.canVideo else { self.fail(.unavailable); return }
            self.reads.once(self.engine.peer(basis.peerID)) { [weak self] result in
                guard let self, !self.stopped else { return }
                guard case let .success(fresh) = result, fresh == basis else { self.fail(.changed); return }
                guard self.captureProxyBasis(), self.emit(.committing) else { return }
                self.committed = true; self.watchProxy()
                self.reads.once(self.engine.request(peer: fresh, video: self.initialVideo, callID: self.callID)) { [weak self] result in
                    guard let self, !self.stopped else { return }
                    guard case let .success(id) = result, id == self.callID else { self.fail(.changed); return }
                    self.installObservers()
                }
            }
        }
    }
    func startIncoming(_ incoming: TelegramIncomingCall) {
        launch = Task { [weak self] in
            guard let self, !self.stopped else { return }
            guard incoming.isValid, incoming.accountID == self.engine.accountID, !self.initialVideo || incoming.isVideo else { self.fail(.unavailable); return }
            self.reads.once(self.engine.incoming()) { [weak self] result in
                guard let self, !self.stopped else { return }
                guard case let .success(values) = result, values.count <= 32, values.contains(incoming) else { self.fail(.changed); return }
                guard self.captureProxyBasis(), self.emit(.committing) else { return }
                self.committed = true; self.watchProxy(); self.installObservers()
                if !self.stopped { self.engine.accept(callID: self.callID) }
            }
        }
    }
    private func captureProxyBasis() -> Bool {
        do {
            proxyBasis = try proxy()
            if let proxyBasis { guard proxyBasis.isValid, case .socks5 = proxyBasis.connection else { fail(.unsupported); return false } }
            return true
        } catch { fail(.unavailable); return false }
    }
    private func installObservers() {
        signaling = engine.receiveSignaling(callID: callID) { [weak self] result in self?.receiveSignaling(result) }
        guard !stopped else { signaling?.cancel(); return }
        observations.add((engine.observe(callID: callID) |> deliverOnMainQueue).start(next: { [weak self] value in
            MainActor.assumeIsolated { self?.observe(value) }
        }, error: { [weak self] _ in MainActor.assumeIsolated { self?.fail(.failed) } }))
    }
    private func observe(_ session: CallSession) {
        guard !stopped else { return }
        guard session.id == callID, session.isOutgoing == outgoing else { fail(.changed); return }
        switch session.state {
        case .ringing, .accepting: if outgoing { fail(.changed) }
        case let .requesting(ringing): if outgoing { _ = emit(.requesting(ringing: ringing)) } else { fail(.changed) }
        case .active:
            do { guard try proxy() == proxyBasis else { fail(.changed); return } } catch { fail(.changed); return }
            guard let value = TelegramCallMediaConfiguration(session: session, internalID: callID, outgoing: outgoing, video: initialVideo, proxy: proxyBasis) else { fail(.unsupported); return }
            videoPossible = session.isVideoPossible
            guard emit(.videoAvailability(videoPossible)) else { return }
            if !videoPossible && videoDesired { fail(.unsupported); return }
            if let configuration { guard configuration == value else { fail(.changed); return }; return }
            configuration = value
            guard emit(.connecting(fingerprint: value.fingerprint)) else { return }
            pendingMediaStart = true
            let created = factory.make(configuration: value) { [weak self] event in self?.mediaEvent(event) ?? false }
            pendingMediaStart = false
            if stopped { created.stop { [weak self] in self?.finishRelease() }; return }
            media = created
            let packets = pending; pending = []; pendingBytes = 0
            for packet in packets { guard !stopped, created.receive(packet) else { fail(.failed); return } }
        case let .dropping(termination), let .terminated(_, termination, _):
            _ = emit(.ended(telegramCallEndExplanation(termination))); stop(completed: {})
        case .switchedToConference:
            _ = emit(.ended("Собеседник перешёл в групповой звонок.")); stop(completed: {})
        }
    }
    private func receiveSignaling(_ result: Result<Data, TelegramCallError>) {
        guard !stopped else { return }
        guard case let .success(data) = result, !data.isEmpty, data.count <= 65536 else { fail(.failed); return }
        if let media { if !media.receive(data) { fail(.failed) }; return }
        guard pending.count < 256, pendingBytes + data.count <= 1024 * 1024 else { fail(.failed); return }
        pending.append(data); pendingBytes += data.count
    }
    private func mediaEvent(_ event: TelegramCallMediaEvent) -> Bool {
        guard !stopped else { return false }
        switch event {
        case .transportConnected: return emit(.transportConnected)
        case .transportReconnecting: return emit(.transportReconnecting)
        case let .remoteVideo(value): return emit(.remoteVideo(value))
        case let .videoFrame(value): return emit(.videoFrame(value))
        case let .localVideoFrame(value): return emit(.localVideoFrame(value))
        case let .signaling(data): engine.send(callID: callID, data: data); return true
        case let .failed(error): fail(error); return false
        }
    }
    private func emit(_ event: TelegramCallEvent) -> Bool {
        guard !stopped else { return false }
        let accepted = receive(event)
        if !accepted { stop(completed: {}) }
        return accepted && !stopped
    }
    private func fail(_ error: TelegramCallError) {
        guard !stopped else { return }; reason = .disconnect
        _ = receive(.failed(error)); stop(completed: {})
    }
    func stop(completed: @escaping @MainActor () -> Void) {
        if released { completed(); return }; completions.append(completed)
        guard !stopped else { return }
        stopped = true; retirement = self; launch?.cancel(); proxyWatch?.cancel()
        reads.cancel(); observations.dispose(); signaling?.cancel(); signaling = nil; pending = []; pendingBytes = 0
        if committed { engine.drop(callID: callID, reason: reason) }
        if let media { media.stop { [weak self] in self?.finishRelease() } }
        else if !pendingMediaStart { finishRelease() }
    }
    private func finishRelease() {
        guard stopped, !released else { return }; released = true; media = nil; retirement = nil
        let values = completions; completions = []; for value in values { value() }
    }
    func setMuted(_ value: Bool) -> Bool { !stopped && media?.setMuted(value) == true }
    func setVideo(_ value: Bool) async -> Bool {
        guard !stopped, !value || videoPossible, let media else { return false }
        let applied = await media.setVideo(value)
        guard !stopped, applied else { return false }; videoDesired = value; engine.updateVideo(callID: callID, enabled: value); return true
    }
    private func watchProxy() {
        proxyWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, !self.stopped else { return }
                do { if try self.proxy() != self.proxyBasis { self.fail(.changed); return } }
                catch { self.fail(.changed); return }
            }
        }
    }
}
func telegramCallEndExplanation(_ value: CallSessionTerminationReason) -> String {
    switch value {
    case .ended(.busy): return "Собеседник занят."
    case .ended(.missed): return "Звонок остался без ответа."
    case .ended(.hungUp): return "Звонок завершён."
    case .ended(.switchedToConference): return "Собеседник перешёл в групповой звонок."
    case .error(.privacyRestricted): return "Звонки этому собеседнику ограничены его настройками."
    case .error(.notSupportedByPeer): return "Собеседник не поддерживает этот звонок."
    case .error(.disconnected): return "Соединение прервано."
    case .error(.generic), .error(.serverProvided): return "Не удалось установить звонок."
    }
}
