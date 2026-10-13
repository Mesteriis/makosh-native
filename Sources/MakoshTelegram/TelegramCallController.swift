import Foundation
import Combine
import CoreVideo

@MainActor public final class TelegramCallController: ObservableObject {
    @Published private(set) var captureReserved = false
    @Published public private(set) var peer: TelegramCallPeer?
    @Published public private(set) var peerStatus: TelegramSearchStatus = .idle
    @Published public private(set) var peerContextID = UUID()
    @Published public private(set) var incoming: [TelegramIncomingCall] = []
    @Published public private(set) var incomingReady = false
    @Published public private(set) var call: TelegramCallSnapshot?
    @Published public private(set) var isReleasingMedia = false
    @Published public private(set) var remoteVideoEnabled = false
    @Published public private(set) var remoteFrame: CVPixelBuffer?
    @Published public private(set) var localFrame: CVPixelBuffer?
    @Published public private(set) var isChangingVideo = false
    public var permitsStart: @MainActor () -> Bool = { true }
    public var accountID: Int64? { provider?.accountID }
    public var isBusy: Bool { call?.isActive == true || isReleasingMedia || coordinator.isBusy }
    private let permissions: any TelegramCallPermissions
    private let coordinator: TelegramCallCoordinator
    private var coordinatorObservation: AnyCancellable?
    private var reservation: UUID?
    private var pendingLeaseStart = false
    private var provider: (any TelegramCallProvider)?
    private var peerRead: (any TelegramCallRequest)?, incomingRead: (any TelegramCallRequest)?
    private var selectedPeerID: Int64?
    private var peerReadID: UUID?, accountContext = UUID(), callContext: UUID?
    private var lease: (any TelegramCallLease)?
    private var retiring: [UUID: any TelegramCallLease] = [:]
    private var authorization: Task<Void, Never>?, permissionWatch: Task<Void, Never>?, peerDeadline: Task<Void, Never>?, lifecycleDeadline: Task<Void, Never>?
    public convenience init(coordinator: TelegramCallCoordinator? = nil) { self.init(permissions: TelegramSystemCallPermissions(), coordinator: coordinator) }
    init(permissions: any TelegramCallPermissions, coordinator: TelegramCallCoordinator? = nil) {
        self.permissions = permissions; self.coordinator = coordinator ?? TelegramCallCoordinator()
        coordinatorObservation = self.coordinator.$isBusy.sink { [weak self] value in self?.captureReserved = value }
    }
    isolated deinit {
        peerRead?.cancel(); incomingRead?.cancel(); authorization?.cancel(); permissionWatch?.cancel()
        peerDeadline?.cancel(); lifecycleDeadline?.cancel()
        let coordinator = coordinator, reservation = reservation
        if let lease { lease.stop { if let reservation { coordinator.release(reservation) } } }
        else if let reservation { coordinator.release(reservation) }
    }
    func bind(_ provider: (any TelegramCallProvider)?) {
        accountContext = UUID(); callContext = nil; lifecycleDeadline?.cancel(); lifecycleDeadline = nil
        authorization?.cancel(); authorization = nil; permissionWatch?.cancel(); permissionWatch = nil
        isChangingVideo = false
        peerReadID = nil; peerRead?.cancel(); incomingRead?.cancel(); peerRead = nil; incomingRead = nil
        peerDeadline?.cancel(); peerDeadline = nil
        if let lease { self.lease = nil; retire(lease, callID: nil, reservation: takeReservation()) }
        else if !pendingLeaseStart { releaseReservation() }
        call = nil; selectedPeerID = nil; peer = nil; peerStatus = .idle; peerContextID = UUID()
        incoming = []; incomingReady = false; remoteFrame = nil; localFrame = nil; remoteVideoEnabled = false
        self.provider = provider
        guard let provider else { return }
        let context = accountContext
        incomingRead = provider.observeIncoming { [weak self] result in
            guard let self, self.accountContext == context, self.accountID == provider.accountID else { return }
            guard case let .success(values) = result, values.count <= 32, Set(values.map(\.id)).count == values.count,
                  values.allSatisfy({ $0.isValid && $0.accountID == provider.accountID }) else { self.incomingReady = false; return }
            self.incoming = values; self.incomingReady = true
        }
    }
    public func refreshPeer() { selectPeer(selectedPeerID) }
    public func selectPeer(_ id: Int64?) {
        selectedPeerID = id
        peerReadID = nil; peerRead?.cancel(); peerRead = nil; peerDeadline?.cancel(); peerDeadline = nil
        peerContextID = UUID(); peer = nil; peerStatus = .idle
        if let call, [.authorizing, .validating].contains(call.phase), call.peerID != id { finish(.failed, explanation: "Выбранный собеседник изменился.") }
        guard let id, let provider else { return }
        let token = UUID(), context = peerContextID
        peerReadID = token; peerStatus = .loading
        peerDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.peerReadID == token else { return }
            self.peerReadID = nil; self.peerRead?.cancel(); self.peerRead = nil; self.peerStatus = .timedOut
        }
        let request = provider.loadPeer(id) { [weak self] result in
            guard let self, self.peerReadID == token, self.peerContextID == context, self.accountID == provider.accountID else { return }
            self.peerReadID = nil; self.peerDeadline?.cancel(); self.peerDeadline = nil; self.peerRead?.cancel(); self.peerRead = nil
            guard case let .success(value) = result, value.isValid, value.accountID == provider.accountID, value.peerID == id else { self.peerStatus = .failed; return }
            self.peer = value; self.peerStatus = .ready
        }
        if peerReadID == token { peerRead = request } else { request.cancel() }
    }
    @discardableResult public func startOutgoing(basis: TelegramCallPeer, video: Bool, contextID: UUID) -> Bool {
        guard permitsStart(), !isBusy, peerStatus == .ready, basis == peer, basis.isValid, basis.accountID == accountID,
              contextID == peerContextID, basis.canVoice, !video || basis.canVideo, let provider, let reservation = coordinator.reserve() else { return false }
        self.reservation = reservation
        let id = UUID(), token = UUID(), account = accountContext
        callContext = token
        call = .init(id: id, accountID: basis.accountID, peerID: basis.peerID, title: basis.title, outgoing: true, phase: .authorizing, videoEnabled: video)
        authorization = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            let allowed = await self.permissions.authorize(video: video)
            guard !Task.isCancelled, self.callContext == token, self.accountContext == account, self.peerContextID == contextID else { return }
            self.authorization = nil
            guard allowed else { self.finish(.failed, explanation: "Нет разрешения на микрофон или камеру."); return }
            self.call?.phase = .validating; self.scheduleTimeout(seconds: 30)
            self.pendingLeaseStart = true
            let request = provider.startOutgoing(basis: basis, video: video, callID: id, receive: self.receiver(token: token, account: account))
            self.pendingLeaseStart = false
            if self.callContext == token { self.lease = request; self.watchPermissions(token: token) }
            else { self.retire(request, callID: nil, reservation: self.takeReservation()) }
        }
        return true
    }
    @discardableResult public func accept(_ incoming: TelegramIncomingCall, video: Bool) -> Bool {
        guard permitsStart(), !isBusy, incomingReady, self.incoming.contains(incoming), incoming.accountID == accountID,
              incoming.isValid, !video || incoming.isVideo, let provider, let reservation = coordinator.reserve() else { return false }
        self.reservation = reservation
        let token = UUID(), account = accountContext; callContext = token
        call = .init(id: incoming.id, accountID: incoming.accountID, peerID: incoming.peerID, title: incoming.title, outgoing: false,
            phase: .authorizing, videoEnabled: video)
        authorization = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            let allowed = await self.permissions.authorize(video: video)
            guard !Task.isCancelled, self.callContext == token, self.accountContext == account else { return }
            self.authorization = nil
            guard allowed, self.incomingReady, self.incoming.contains(incoming) else { self.finish(.failed, explanation: allowed ? "Входящий звонок изменился или завершился." : "Нет разрешения на микрофон или камеру."); return }
            self.call?.phase = .validating; self.scheduleTimeout(seconds: 30)
            self.pendingLeaseStart = true
            let request = provider.accept(incoming: incoming, video: video, receive: self.receiver(token: token, account: account))
            self.pendingLeaseStart = false
            if self.callContext == token { self.lease = request; self.watchPermissions(token: token) }
            else { self.retire(request, callID: nil, reservation: self.takeReservation()) }
        }
        return true
    }
    @discardableResult public func decline(_ value: TelegramIncomingCall) -> Bool {
        guard incomingReady, incoming.contains(value), value.isValid, value.accountID == accountID, call?.id != value.id else { return false }
        provider?.decline(incoming: value); return true
    }
    private func receiver(token: UUID, account: UUID) -> @MainActor (TelegramCallEvent) -> Bool {
        { [weak self] event in
            guard let self, self.callContext == token, self.accountContext == account, let phase = self.call?.phase else { return false }
            switch event {
            case .committing:
                guard phase == .validating else { return false }
                guard self.permitsStart(), self.permissions.isAuthorized(video: self.call?.videoEnabled == true) else {
                    self.finish(.failed, explanation: "Нет разрешения на микрофон или камеру."); return false
                }
                self.call?.phase = .requesting; self.scheduleTimeout(seconds: 90)
            case let .requesting(ringing):
                guard phase == .requesting else { return false }; self.call?.ringing = ringing
            case let .connecting(fingerprint):
                guard phase == .requesting, fingerprint.count == 32 else { return false }
                self.call?.fingerprint = fingerprint; self.call?.phase = .connecting; self.scheduleTimeout(seconds: 30)
            case .transportConnected:
                guard [.connecting, .reconnecting].contains(phase), self.call?.fingerprint?.count == 32 else { return false }; self.call?.phase = .connected; if self.call?.connectedAt == nil { self.call?.connectedAt = Date() }; self.lifecycleDeadline?.cancel(); self.lifecycleDeadline = nil
            case .transportReconnecting:
                guard phase == .connected else { return false }; self.call?.phase = .reconnecting; self.scheduleTimeout(seconds: 20)
            case let .remoteVideo(enabled): self.remoteVideoEnabled = enabled; if !enabled { self.remoteFrame = nil }
            case let .videoFrame(frame):
                guard [.connected, .reconnecting].contains(phase), telegramCallFrameAdmitted(frame) else { return false }
                self.remoteFrame = frame
            case let .localVideoFrame(frame):
                guard [.connecting, .connected, .reconnecting].contains(phase), telegramCallFrameAdmitted(frame) else { return false }
                if self.call?.videoEnabled == true || self.isChangingVideo { self.localFrame = frame }
            case let .videoAvailability(value): self.call?.canVideo = value
            case let .ended(explanation): self.finish(.ended, explanation: explanation)
            case .failed: self.finish(.failed, explanation: "Не удалось установить звонок.")
            }
            return true
        }
    }
    public func end(callID: UUID) { guard call?.id == callID, call?.isActive == true else { return }; finish(.ending, explanation: nil) }
    public func dismissEnded() { guard call?.isActive == false, !isReleasingMedia else { return }; call = nil; remoteFrame = nil }
    private func finish(_ phase: TelegramCallSnapshot.Phase, explanation: String?) {
        callContext = nil; lifecycleDeadline?.cancel(); lifecycleDeadline = nil; authorization?.cancel(); authorization = nil; permissionWatch?.cancel(); permissionWatch = nil
        isChangingVideo = false
        call?.phase = phase; call?.explanation = explanation; remoteFrame = nil; localFrame = nil; remoteVideoEnabled = false
        if let lease { self.lease = nil; retire(lease, callID: call?.id, reservation: takeReservation()) }
        else {
            if !pendingLeaseStart { releaseReservation() }
            if phase == .ending { call?.phase = .ended }
        }
    }
    private func takeReservation() -> UUID? { let value = reservation; reservation = nil; return value }
    private func releaseReservation() { if let value = takeReservation() { coordinator.release(value) } }
    private func retire(_ lease: any TelegramCallLease, callID: UUID?, reservation: UUID?) {
        let token = UUID(); retiring[token] = lease; isReleasingMedia = true
        let coordinator = coordinator
        lease.stop { [weak self] in
            if let reservation { coordinator.release(reservation) }
            guard let self else { return }; self.retiring[token] = nil; self.isReleasingMedia = !self.retiring.isEmpty
            if let callID, self.call?.id == callID, self.call?.phase == .ending { self.call?.phase = .ended }
        }
    }
    @discardableResult public func setMuted(_ value: Bool, callID: UUID) -> Bool {
        guard call?.id == callID, [.connected, .reconnecting].contains(call?.phase), let lease, lease.setMuted(value) else { return false }
        call?.muted = value; return true
    }
    public func setVideo(_ value: Bool, callID: UUID) async -> Bool {
        guard call?.id == callID, [.connected, .reconnecting].contains(call?.phase), !isChangingVideo, let lease, let context = callContext else { return false }
        isChangingVideo = true
        let allowed: Bool
        if value { allowed = await permissions.authorize(video: true) } else { allowed = true }
        guard call?.id == callID, callContext == context else { return false }
        guard allowed else { isChangingVideo = false; return false }
        let applied = await lease.setVideo(value)
        guard call?.id == callID, callContext == context else { return false }
        isChangingVideo = false
        guard applied else { return false }; call?.videoEnabled = value; if !value { localFrame = nil }; return true
    }
    func timeoutCall(callID: UUID) {
        guard call?.id == callID, [.validating, .requesting, .connecting, .reconnecting].contains(call?.phase) else { return }
        finish(.failed, explanation: "Время ожидания звонка истекло. Соединение остановлено.")
    }
    private func scheduleTimeout(seconds: Double) {
        lifecycleDeadline?.cancel()
        guard let context = callContext, let call else { return }
        lifecycleDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.callContext == context, self.call?.phase == call.phase else { return }
            self.timeoutCall(callID: call.id)
        }
    }
    func checkPermissions() {
        guard let call, callContext != nil, ![.authorizing, .validating].contains(call.phase) else { return }
        if !permissions.isAuthorized(video: call.videoEnabled) { finish(.ending, explanation: "Доступ к микрофону или камере отозван.") }
    }
    private func watchPermissions(token: UUID) {
        permissionWatch?.cancel()
        permissionWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.callContext == token else { return }; self.checkPermissions()
            }
        }
    }
}
