import XCTest
import TelegramCore
import SwiftSignalKit
import CoreVideo
@testable import MakoshTelegram

@MainActor final class TelegramEngineCallProviderTests: XCTestCase {
    private func start(_ engine: CallEngineFixture, _ factory: CallMediaFactoryFixture) async throws -> TelegramCallController {
        let controller = TelegramCallController(permissions: EngineCallPermissions())
        controller.bind(TelegramEngineCallProvider(engine: engine, proxy: { nil }, media: factory))
        controller.selectPeer(42)
        XCTAssertTrue(controller.startOutgoing(basis: engine.peerValue, video: false, contextID: controller.peerContextID))
        await fulfillment(of: [engine.requested], timeout: 2)
        return controller
    }
    private func drain() async { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
    func testAuthenticatedSessionOnlyStartsMediaAndTransportOnlyConnectsUI() async throws {
        let engine = CallEngineFixture(), factory = CallMediaFactoryFixture(), controller = try await start(engine, factory)
        XCTAssertEqual(controller.call?.phase, .requesting); XCTAssertTrue(factory.cores.isEmpty)
        engine.emit(engine.active()); await drain()
        XCTAssertEqual(factory.cores.count, 1); XCTAssertEqual(controller.call?.phase, .connecting)
        factory.cores[0].inbox?.enqueue(.state(2)); await drain()
        XCTAssertEqual(controller.call?.phase, .connected)
        controller.end(callID: try XCTUnwrap(controller.call?.id))
        XCTAssertEqual(engine.dropped.map(\.0), [engine.id]); XCTAssertTrue(controller.isReleasingMedia)
        factory.cores[0].inbox?.release(); await drain(); XCTAssertFalse(controller.isReleasingMedia)
    }
    func testFreshPeerChangeRefusesRequestBeforeAnyRemoteCommit() async throws {
        let engine = CallEngineFixture(), factory = CallMediaFactoryFixture()
        let controller = TelegramCallController(permissions: EngineCallPermissions())
        controller.bind(TelegramEngineCallProvider(engine: engine, proxy: { nil }, media: factory)); controller.selectPeer(42)
        let basis = engine.peerValue
        engine.peerValue = .init(accountID: 101, peerID: 42, title: "Changed synthetic user", canVoice: false, canVideo: false, revision: String(repeating: "b", count: 64))
        XCTAssertTrue(controller.startOutgoing(basis: basis, video: false, contextID: controller.peerContextID))
        for _ in 0..<20 { await Task.yield() }; await drain()
        XCTAssertTrue(engine.requests.isEmpty); XCTAssertTrue(factory.cores.isEmpty); XCTAssertEqual(controller.call?.phase, .failed)
    }
    func testForeignRequestReceiptNeverStartsMediaOrDropsForeignCall() async throws {
        let engine = CallEngineFixture(), factory = CallMediaFactoryFixture(); engine.returnedID = UUID()
        let controller = try await start(engine, factory); await drain()
        XCTAssertTrue(factory.cores.isEmpty); XCTAssertEqual(controller.call?.phase, .failed)
        XCTAssertEqual(engine.dropped.map(\.0), [engine.id])
    }
    func testWrongNativeSessionContextAndMalformedKeyNeverStartCapture() async throws {
        for wrongID in [false, true] {
            let engine = CallEngineFixture(), factory = CallMediaFactoryFixture(), controller = try await start(engine, factory)
            engine.emit(engine.active(id: wrongID ? UUID() : engine.id, keySize: wrongID ? 256 : 255)); await drain()
            XCTAssertTrue(factory.cores.isEmpty); XCTAssertEqual(controller.call?.phase, .failed)
            XCTAssertEqual(engine.dropped.map(\.0), [engine.id])
        }
    }
    func testPreActiveSignalingIsBufferedAndLateAccountCallbacksAreRejected() async throws {
        let engine = CallEngineFixture(), factory = CallMediaFactoryFixture(), controller = try await start(engine, factory)
        engine.signaling?(.success(Data([17, 23])))
        XCTAssertTrue(factory.cores.isEmpty)
        engine.emit(engine.active()); await drain()
        XCTAssertEqual(factory.cores[0].packets, [Data([17, 23])])
        controller.bind(nil); engine.signaling?(.success(Data([99]))); await drain()
        XCTAssertEqual(factory.cores[0].packets.count, 1); XCTAssertEqual(factory.cores[0].stops, 1)
        factory.cores[0].inbox?.release(); await drain()
    }
    func testSignalingOverflowFailsClosedBeforeMediaAllocation() async throws {
        let engine = CallEngineFixture(), factory = CallMediaFactoryFixture(), controller = try await start(engine, factory)
        for _ in 0..<17 { engine.signaling?(.success(Data(count: 65536))) }
        await drain()
        XCTAssertTrue(factory.cores.isEmpty); XCTAssertEqual(controller.call?.phase, .failed)
        XCTAssertEqual(engine.dropped.count, 1)
    }
    func testIncomingObservationIsInertAndAcceptRequiresFreshExactRingingState() async throws {
        let engine = CallEngineFixture(), factory = CallMediaFactoryFixture(), permissions = EngineCallPermissions()
        let incoming = TelegramIncomingCall(id: UUID(), accountID: 101, peerID: 42, title: "Synthetic incoming", isVideo: true)
        engine.seedIncoming(incoming)
        let controller = TelegramCallController(permissions: permissions)
        controller.bind(TelegramEngineCallProvider(engine: engine, proxy: { nil }, media: factory))
        XCTAssertEqual(controller.incoming, [incoming]); XCTAssertEqual(permissions.requests, 0); XCTAssertTrue(factory.cores.isEmpty)
        XCTAssertTrue(controller.accept(incoming, video: false))
        await fulfillment(of: [engine.acceptedCall], timeout: 2)
        engine.emit(engine.active(outgoing: false)); await drain()
        XCTAssertEqual(factory.configurations.first?.outgoing, false); XCTAssertEqual(factory.configurations.first?.video, false)
        controller.end(callID: incoming.id); factory.cores[0].inbox?.release(); await drain()
    }
    func testProxyChangeBeforeActiveStateNeverStartsMedia() async throws {
        let engine = CallEngineFixture(), factory = CallMediaFactoryFixture()
        var proxy: TelegramProxyServer?
        let controller = TelegramCallController(permissions: EngineCallPermissions())
        controller.bind(TelegramEngineCallProvider(engine: engine, proxy: { proxy }, media: factory)); controller.selectPeer(42)
        XCTAssertTrue(controller.startOutgoing(basis: engine.peerValue, video: false, contextID: controller.peerContextID))
        await fulfillment(of: [engine.requested], timeout: 2)
        var draft = TelegramProxyDraft(); draft.host = "127.0.0.1"; draft.port = "1080"; proxy = try TelegramProxyServer(draft: draft)
        engine.emit(engine.active()); await drain()
        XCTAssertTrue(factory.cores.isEmpty); XCTAssertEqual(controller.call?.phase, .failed)
    }
    func testSynchronousMediaFactoryFailureStillWaitsForReturnedMediaRelease() async throws {
        let engine = CallEngineFixture(), factory = CallMediaFactoryFixture(); factory.failDuringCreation = true
        let controller = try await start(engine, factory)
        engine.emit(engine.active()); await drain()
        XCTAssertEqual(controller.call?.phase, .failed); XCTAssertTrue(controller.isReleasingMedia)
        XCTAssertEqual(factory.cores[0].stops, 1)
        factory.cores[0].inbox?.release(); await drain(); XCTAssertFalse(controller.isReleasingMedia)
    }
}
@MainActor private final class EngineCallPermissions: TelegramCallPermissions {
    var requests = 0
    func authorize(video: Bool) async -> Bool { requests += 1; return true }
    func isAuthorized(video: Bool) -> Bool { true }
}
@MainActor private final class EngineCallRequest: TelegramCallRequest { func cancel() {} }
@MainActor private final class CallEngineFixture: TelegramCallEngine {
    let accountID: Int64 = 101
    var peerValue = TelegramCallPeer(accountID: 101, peerID: 42, title: "Synthetic Alice", canVoice: true, canVideo: true, revision: String(repeating: "a", count: 64))
    var id = UUID(), returnedID: UUID?
    var requests: [UUID] = [], dropped: [(UUID, DropCallReason)] = []
    let requested = XCTestExpectation(description: "Native request issued"), acceptedCall = XCTestExpectation(description: "Current incoming call accepted")
    private let ringing = ValuePromise<[TelegramIncomingCall]>([], ignoreRepeated: true)
    private let state = Promise<CallSession>()
    var signaling: (@MainActor (Result<Data, TelegramCallError>) -> Void)?
    func peer(_ id: Int64) -> Signal<TelegramCallPeer, TelegramCallError> { .single(peerValue) }
    func incoming() -> Signal<[TelegramIncomingCall], TelegramCallError> { ringing.get() |> castError(TelegramCallError.self) }
    func request(peer: TelegramCallPeer, video: Bool, callID: UUID) -> Signal<UUID, TelegramCallError> {
        id = callID; requests.append(callID); state.set(.single(.init(id: id, stableId: nil, isOutgoing: true, type: .audio, state: .requesting(ringing: false), isVideoPossible: true)))
        requested.fulfill(); return .single(returnedID ?? callID)
    }
    func observe(callID: UUID) -> Signal<CallSession, TelegramCallError> { state.get() |> castError(TelegramCallError.self) }
    func receiveSignaling(callID: UUID, receive: @escaping @MainActor (Result<Data, TelegramCallError>) -> Void) -> any TelegramCallRequest { signaling = receive; return EngineCallRequest() }
    func accept(callID: UUID) { acceptedCall.fulfill(); state.set(.single(.init(id: callID, stableId: nil, isOutgoing: false, type: .video, state: .accepting, isVideoPossible: true))) }
    func drop(callID: UUID, reason: DropCallReason) { dropped.append((callID, reason)) }
    func send(callID: UUID, data: Data) {}
    func updateVideo(callID: UUID, enabled: Bool) {}
    func seedIncoming(_ value: TelegramIncomingCall) {
        id = value.id; state.set(.single(.init(id: id, stableId: nil, isOutgoing: false, type: .video, state: .ringing, isVideoPossible: true))); ringing.set([value])
    }
    func emit(_ value: CallSession) { state.set(.single(value)) }
    func active(id: UUID? = nil, outgoing: Bool = true, keySize: Int = 256) -> CallSession {
        .init(id: id ?? self.id, stableId: 11, isOutgoing: outgoing, type: .video,
            state: .active(id: .init(id: 11, accessHash: 12), key: Data(repeating: 7, count: keySize), keyVisualHash: Data(repeating: 9, count: 32),
                connections: .init(primary: .reflector(.init(id: 21, ip: "203.0.113.17", ipv6: "", isTcp: false, port: 443, peerTag: Data(repeating: 3, count: 16))), alternatives: []),
                maxLayer: 92, version: "5.0.0", customParameters: nil, allowsP2P: true, supportsConferenceCalls: false), isVideoPossible: true)
    }
}
@MainActor private final class CallMediaFactoryFixture: TelegramCallMediaFactory {
    var cores: [EngineMediaCore] = [], configurations: [TelegramCallMediaConfiguration] = []
    var failDuringCreation = false
    func make(configuration: TelegramCallMediaConfiguration, receive: @escaping @MainActor (TelegramCallMediaEvent) -> Bool) -> TelegramCallMediaSession {
        configurations.append(configuration)
        if failDuringCreation { _ = receive(.failed(.failed)) }
        let core = EngineMediaCore(); cores.append(core)
        return .init(makeCore: { inbox in core.inbox = inbox; return core }, makeCamera: { EngineMediaCamera() }, video: configuration.video, receive: receive)
    }
}
@MainActor private final class EngineMediaCore: TelegramCallNativeBridge {
    var inbox: TelegramCallMediaInbox?, stops = 0, packets: [Data] = []
    var videoOutput: @Sendable (CVPixelBuffer) -> Void { { _ in } }
    func stop() { stops += 1 }
    func setMuted(_ value: Bool) -> Bool { true }
    func setVideo(_ value: Bool) -> Bool { true }
    func receive(_ data: Data) -> Bool { packets.append(data); return true }
}
@MainActor private final class EngineMediaCamera: TelegramCallCameraSource {
    func start(output: @escaping @Sendable (CVPixelBuffer) -> Void, failure: @escaping @MainActor () -> Void) async -> Bool { true }
    func stop(completed: @escaping @MainActor () -> Void) { completed() }
}
