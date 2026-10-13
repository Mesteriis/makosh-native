import XCTest
import Foundation
import CoreVideo
@testable import MakoshTelegram

@MainActor final class TelegramCallControllerTests: XCTestCase {
    private var peer: TelegramCallPeer {
        .init(accountID: 101, peerID: 42, title: "Synthetic Alice", canVoice: true, canVideo: true, revision: String(repeating: "a", count: 64))
    }
    private func ready(_ controller: TelegramCallController, _ provider: CallTestProvider) {
        controller.bind(provider); controller.selectPeer(42); provider.peerReads.last?(.success(peer))
    }
    private func start(_ controller: TelegramCallController, _ provider: CallTestProvider, video: Bool = false) async throws -> UUID {
        ready(controller, provider)
        XCTAssertTrue(controller.startOutgoing(basis: peer, video: video, contextID: controller.peerContextID))
        for _ in 0..<20 where provider.calls.isEmpty { await Task.yield() }
        XCTAssertEqual(provider.calls.count, 1)
        return try XCTUnwrap(controller.call?.id)
    }
    func testCallPresentationUsesCurrentNativeVideoCapabilityAndClearsLocalPreview() async throws {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        let id = try await start(controller, provider, video: true)
        _ = provider.calls[0].receive(.committing)
        _ = provider.calls[0].receive(.requesting(ringing: true))
        XCTAssertEqual(controller.call?.ringing, true)
        _ = provider.calls[0].receive(.videoAvailability(true))
        XCTAssertEqual(controller.call?.canVideo, true)
        _ = provider.calls[0].receive(.connecting(fingerprint: Data(count: 32)))
        _ = provider.calls[0].receive(.transportConnected)
        XCTAssertNotNil(controller.call?.connectedAt)
        var frame: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 240, 320, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &frame), kCVReturnSuccess)
        XCTAssertTrue(provider.calls[0].receive(.localVideoFrame(try XCTUnwrap(frame))))
        XCTAssertNotNil(controller.localFrame)
        XCTAssertTrue(provider.calls[0].receive(.videoFrame(try XCTUnwrap(frame))))
        XCTAssertNotNil(controller.remoteFrame)
        controller.end(callID: id)
        XCTAssertNil(controller.localFrame); XCTAssertNil(controller.remoteFrame)
    }
    func testRecordingReservationBlocksCallBeforePermissionAndAgainBeforeWireCommit() async throws {
        let provider = CallTestProvider(), permissions = CallTestPermissions(), controller = TelegramCallController(permissions: permissions)
        ready(controller, provider); controller.permitsStart = { false }
        XCTAssertFalse(controller.startOutgoing(basis: peer, video: false, contextID: controller.peerContextID))
        XCTAssertEqual(permissions.requests, 0)
        controller.permitsStart = { true }
        _ = try await start(controller, provider)
        controller.permitsStart = { false }
        XCTAssertFalse(provider.calls[0].receive(.committing))
        XCTAssertEqual(controller.call?.phase, .failed)
    }
    func testFirstPreviewDuringCameraStartDoesNotRejectCurrentCall() async throws {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        let id = try await start(controller, provider)
        _ = provider.calls[0].receive(.committing); _ = provider.calls[0].receive(.connecting(fingerprint: Data(count: 32)))
        _ = provider.calls[0].receive(.transportConnected)
        provider.calls[0].lease.delayVideo = true
        let change = Task { await controller.setVideo(true, callID: id) }
        for _ in 0..<20 where provider.calls[0].lease.videoWaiter == nil { await Task.yield() }
        var frame: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &frame), kCVReturnSuccess)
        XCTAssertTrue(provider.calls[0].receive(.localVideoFrame(try XCTUnwrap(frame))))
        XCTAssertNotNil(controller.localFrame)
        provider.calls[0].lease.videoWaiter?.resume(returning: true)
        let changed = await change.value; XCTAssertTrue(changed)
    }
    func testRetryUsesCurrentSelectionAndRejectsLateFailedLookup() {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        controller.bind(provider); controller.selectPeer(42)
        let old = provider.peerReads[0]
        old(.failure(.failed)); XCTAssertEqual(controller.peerStatus, .failed)
        controller.refreshPeer()
        XCTAssertEqual(provider.peerReads.count, 2); XCTAssertEqual(controller.peerStatus, .loading)
        old(.success(peer)); XCTAssertNil(controller.peer)
        provider.peerReads[1](.success(peer)); XCTAssertEqual(controller.peerStatus, .ready)
    }
    func testCancellationBeforePermissionTaskPreventsLateAuthorizationRequest() async throws {
        for incoming in [false, true] {
            let provider = CallTestProvider(), permissions = CallTestPermissions(), controller = TelegramCallController(permissions: permissions)
            ready(controller, provider)
            if incoming {
                let row = TelegramIncomingCall(id: UUID(), accountID: 101, peerID: 42, title: "Synthetic Alice", isVideo: false)
                provider.incoming?(.success([row])); XCTAssertTrue(controller.accept(row, video: false))
            } else { XCTAssertTrue(controller.startOutgoing(basis: peer, video: false, contextID: controller.peerContextID)) }
            controller.end(callID: try XCTUnwrap(controller.call?.id))
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(permissions.requests, 0); XCTAssertTrue(provider.calls.isEmpty)
        }
    }
    func testOutgoingConsentIsBoundToCurrentAccountPeerAndContext() async {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        ready(controller, provider)
        XCTAssertFalse(controller.startOutgoing(basis: peer, video: false, contextID: UUID()))
        controller.selectPeer(43)
        XCTAssertFalse(controller.startOutgoing(basis: peer, video: false, contextID: controller.peerContextID))
        XCTAssertTrue(provider.calls.isEmpty)
    }
    func testPermissionDenialDoesNotBeginSignalingOrMedia() async {
        let provider = CallTestProvider(), permissions = CallTestPermissions(); permissions.allowed = false
        let controller = TelegramCallController(permissions: permissions); ready(controller, provider)
        XCTAssertTrue(controller.startOutgoing(basis: peer, video: true, contextID: controller.peerContextID))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(controller.call?.phase, .failed); XCTAssertTrue(provider.calls.isEmpty)
    }
    func testAuthenticatedSessionDoesNotPretendTransportIsConnected() async throws {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        let id = try await start(controller, provider)
        XCTAssertTrue(provider.calls[0].receive(.committing))
        XCTAssertTrue(provider.calls[0].receive(.connecting(fingerprint: Data(repeating: 0x5a, count: 32))))
        XCTAssertEqual(controller.call?.phase, .connecting)
        XCTAssertTrue(provider.calls[0].receive(.transportConnected))
        XCTAssertEqual(controller.call?.id, id); XCTAssertEqual(controller.call?.phase, .connected)
    }
    func testUnknownOrMalformedFingerprintCannotBecomeAConnectedCall() async throws {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        _ = try await start(controller, provider)
        XCTAssertFalse(provider.calls[0].receive(.transportConnected))
        XCTAssertTrue(provider.calls[0].receive(.committing))
        XCTAssertFalse(provider.calls[0].receive(.connecting(fingerprint: Data(count: 31))))
        XCTAssertNotEqual(controller.call?.phase, .connected)
    }
    func testRebindRevokesLateCallbacksAndBlocksNewCaptureUntilStopAcknowledgement() async throws {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        _ = try await start(controller, provider)
        _ = provider.calls[0].receive(.committing)
        let next = CallTestProvider(accountID: 102)
        controller.bind(next)
        XCTAssertEqual(provider.calls[0].lease.stopCount, 1); XCTAssertTrue(controller.isReleasingMedia)
        XCTAssertFalse(provider.calls[0].receive(.connecting(fingerprint: Data(count: 32))))
        XCTAssertNil(controller.call)
        provider.calls[0].lease.completeStop?()
        XCTAssertFalse(controller.isReleasingMedia); XCTAssertEqual(controller.accountID, 102)
    }
    func testEndWaitsForActualReleaseAndRejectsLateMediaEvents() async throws {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        let id = try await start(controller, provider)
        _ = provider.calls[0].receive(.committing); _ = provider.calls[0].receive(.connecting(fingerprint: Data(count: 32)))
        _ = provider.calls[0].receive(.transportConnected)
        controller.end(callID: id)
        XCTAssertEqual(controller.call?.phase, .ending); XCTAssertTrue(controller.isReleasingMedia)
        XCTAssertFalse(provider.calls[0].receive(.transportConnected))
        provider.calls[0].lease.completeStop?()
        XCTAssertEqual(controller.call?.phase, .ended); XCTAssertFalse(controller.isReleasingMedia)
    }
    func testConnectingTimeoutReleasesMediaAndAnOldIDCannotEndAnotherCall() async throws {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        let id = try await start(controller, provider)
        _ = provider.calls[0].receive(.committing); _ = provider.calls[0].receive(.connecting(fingerprint: Data(count: 32)))
        controller.timeoutCall(callID: UUID())
        XCTAssertEqual(controller.call?.phase, .connecting)
        controller.timeoutCall(callID: id)
        XCTAssertEqual(provider.calls[0].lease.stopCount, 1); XCTAssertTrue(controller.isReleasingMedia)
        XCTAssertEqual(controller.call?.phase, .failed)
        XCTAssertFalse(provider.calls[0].receive(.transportConnected))
    }
    func testConnectedCallHasNoSetupDeadline() async throws {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        let id = try await start(controller, provider)
        _ = provider.calls[0].receive(.committing); _ = provider.calls[0].receive(.connecting(fingerprint: Data(count: 32)))
        _ = provider.calls[0].receive(.transportConnected)
        controller.timeoutCall(callID: id)
        XCTAssertEqual(controller.call?.phase, .connected); XCTAssertEqual(provider.calls[0].lease.stopCount, 0)
    }
    func testIncomingDoesNotAuthorizeOrCaptureUntilExplicitAccept() async {
        let provider = CallTestProvider(), permissions = CallTestPermissions(), controller = TelegramCallController(permissions: permissions)
        controller.bind(provider)
        let incoming = TelegramIncomingCall(id: UUID(), accountID: 101, peerID: 42, title: "Synthetic Alice", isVideo: true)
        provider.incoming?(.success([incoming]))
        XCTAssertEqual(controller.incoming, [incoming]); XCTAssertEqual(permissions.requests, 0); XCTAssertTrue(provider.calls.isEmpty)
        controller.decline(incoming)
        XCTAssertEqual(provider.declined, [incoming.id]); XCTAssertEqual(permissions.requests, 0)
    }
    func testIncomingAcceptRequiresExactCurrentObservedCall() async {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        controller.bind(provider)
        let incoming = TelegramIncomingCall(id: UUID(), accountID: 101, peerID: 42, title: "Synthetic Alice", isVideo: true)
        provider.incoming?(.success([incoming]))
        provider.incoming?(.success([]))
        XCTAssertFalse(controller.accept(incoming, video: false)); XCTAssertTrue(provider.calls.isEmpty)
    }
    func testCameraChangeRemainsPendingUntilTheLeaseAcknowledgesCapture() async throws {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        let id = try await start(controller, provider)
        _ = provider.calls[0].receive(.committing); _ = provider.calls[0].receive(.connecting(fingerprint: Data(count: 32)))
        _ = provider.calls[0].receive(.transportConnected); provider.calls[0].lease.delayVideo = true
        let change = Task { await controller.setVideo(true, callID: id) }
        for _ in 0..<20 where provider.calls[0].lease.videoWaiter == nil { await Task.yield() }
        XCTAssertTrue(controller.isChangingVideo); XCTAssertFalse(controller.call?.videoEnabled ?? true)
        let waiter = try XCTUnwrap(provider.calls[0].lease.videoWaiter); provider.calls[0].lease.videoWaiter = nil; waiter.resume(returning: true)
        let changed = await change.value; XCTAssertTrue(changed); XCTAssertTrue(controller.call?.videoEnabled ?? false)
        XCTAssertFalse(controller.isChangingVideo)
        controller.bind(nil); provider.calls[0].lease.completeStop?()
    }
    func testLateCameraAcknowledgementCannotApplyAfterAccountRebinding() async throws {
        let provider = CallTestProvider(), controller = TelegramCallController(permissions: CallTestPermissions())
        let id = try await start(controller, provider)
        _ = provider.calls[0].receive(.committing); _ = provider.calls[0].receive(.connecting(fingerprint: Data(count: 32)))
        _ = provider.calls[0].receive(.transportConnected); provider.calls[0].lease.delayVideo = true
        let change = Task { await controller.setVideo(true, callID: id) }
        for _ in 0..<20 where provider.calls[0].lease.videoWaiter == nil { await Task.yield() }
        let waiter = try XCTUnwrap(provider.calls[0].lease.videoWaiter); provider.calls[0].lease.videoWaiter = nil
        controller.bind(CallTestProvider(accountID: 102)); waiter.resume(returning: true)
        let changed = await change.value; XCTAssertFalse(changed)
        XCTAssertNil(controller.call); XCTAssertFalse(controller.isChangingVideo)
        provider.calls[0].lease.completeStop?()
    }
    func testRevokedPermissionBeforeCommitNeverStartsNativeSignaling() async throws {
        let permissions = CallTestPermissions(), provider = CallTestProvider()
        let controller = TelegramCallController(permissions: permissions)
        _ = try await start(controller, provider)
        permissions.allowed = false
        XCTAssertFalse(provider.calls[0].receive(.committing))
        XCTAssertEqual(controller.call?.phase, .failed)
        XCTAssertEqual(provider.calls[0].lease.stopCount, 1)
        provider.calls[0].lease.completeStop?()
    }
    func testSharedCoordinatorBlocksAnotherAccountUntilNativeRelease() async throws {
        let coordinator = TelegramCallCoordinator()
        let first = CallTestProvider(), second = CallTestProvider(accountID: 102)
        let permissions = CallTestPermissions()
        let a = TelegramCallController(permissions: CallTestPermissions(), coordinator: coordinator)
        let b = TelegramCallController(permissions: permissions, coordinator: coordinator)
        let id = try await start(a, first)
        let other = TelegramCallPeer(accountID: 102, peerID: 42, title: "Synthetic Alice", canVoice: true, canVideo: true, revision: String(repeating: "b", count: 64))
        b.bind(second); b.selectPeer(42); second.peerReads[0](.success(other))
        XCTAssertFalse(b.startOutgoing(basis: other, video: false, contextID: b.peerContextID)); XCTAssertEqual(permissions.requests, 0)
        a.end(callID: id)
        XCTAssertTrue(coordinator.isBusy)
        XCTAssertFalse(b.startOutgoing(basis: other, video: false, contextID: b.peerContextID))
        first.calls[0].lease.completeStop?()
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertTrue(b.startOutgoing(basis: other, video: false, contextID: b.peerContextID))
        for _ in 0..<20 where second.calls.isEmpty { await Task.yield() }
        XCTAssertEqual(permissions.requests, 1)
        first.calls[0].lease.completeStop?() // Old duplicate release cannot free the new reservation.
        XCTAssertTrue(coordinator.isBusy)
        b.bind(nil); second.calls[0].lease.completeStop?(); XCTAssertFalse(coordinator.isBusy)
    }
    func testSynchronousProviderFailureStillHoldsReservationUntilReturnedLeaseReleases() async throws {
        let coordinator = TelegramCallCoordinator(), provider = CallTestProvider(); provider.failDuringStart = true
        let controller = TelegramCallController(permissions: CallTestPermissions(), coordinator: coordinator)
        _ = try await start(controller, provider)
        XCTAssertEqual(controller.call?.phase, .failed)
        XCTAssertTrue(coordinator.isBusy); XCTAssertTrue(controller.isReleasingMedia)
        XCTAssertEqual(provider.calls[0].lease.stopCount, 1)
        provider.calls[0].lease.completeStop?(); XCTAssertFalse(coordinator.isBusy)
    }
    func testControllerDeinitKeepsReservationUntilMediaRelease() async throws {
        let coordinator = TelegramCallCoordinator(), provider = CallTestProvider()
        var controller: TelegramCallController? = TelegramCallController(permissions: CallTestPermissions(), coordinator: coordinator)
        _ = try await start(try XCTUnwrap(controller), provider)
        controller = nil
        XCTAssertEqual(provider.calls[0].lease.stopCount, 1); XCTAssertTrue(coordinator.isBusy)
        provider.calls[0].lease.completeStop?(); XCTAssertFalse(coordinator.isBusy)
    }
    func testMuteAdmissionAndPermissionRevocationReleaseCurrentMedia() async throws {
        let permissions = CallTestPermissions(), provider = CallTestProvider(), controller = TelegramCallController(permissions: permissions)
        let id = try await start(controller, provider)
        _ = provider.calls[0].receive(.committing); _ = provider.calls[0].receive(.connecting(fingerprint: Data(count: 32)))
        _ = provider.calls[0].receive(.transportConnected)
        XCTAssertTrue(controller.setMuted(true, callID: id)); XCTAssertEqual(provider.calls[0].lease.muted, true)
        XCTAssertFalse(controller.setMuted(false, callID: UUID()))
        permissions.allowed = false; controller.checkPermissions()
        XCTAssertEqual(provider.calls[0].lease.stopCount, 1); XCTAssertEqual(controller.call?.phase, .ending)
    }
}

@MainActor private final class CallTestPermissions: TelegramCallPermissions {
    var allowed = true, requests = 0
    func authorize(video: Bool) async -> Bool { requests += 1; return allowed }
    func isAuthorized(video: Bool) -> Bool { allowed }
}
@MainActor private final class CallTestRequest: TelegramCallRequest { func cancel() {} }
@MainActor private final class CallTestLease: TelegramCallLease {
    var stopCount = 0, muted = false, delayVideo = false
    var videoWaiter: CheckedContinuation<Bool, Never>?
    var completeStop: (@MainActor () -> Void)?
    func stop(completed: @escaping @MainActor () -> Void) { stopCount += 1; completeStop = completed }
    func setMuted(_ value: Bool) -> Bool { muted = value; return true }
    func setVideo(_ value: Bool) async -> Bool {
        if !delayVideo { return true }
        return await withCheckedContinuation { videoWaiter = $0 }
    }
}
@MainActor private final class CallTestProvider: TelegramCallProvider {
    let accountID: Int64
    var peerReads: [@MainActor (Result<TelegramCallPeer, TelegramCallError>) -> Void] = []
    var incoming: (@MainActor (Result<[TelegramIncomingCall], TelegramCallError>) -> Void)?
    struct Call { let id: UUID; let receive: @MainActor (TelegramCallEvent) -> Bool; let lease: CallTestLease }
    var calls: [Call] = [], declined: [UUID] = []
    var failDuringStart = false
    init(accountID: Int64 = 101) { self.accountID = accountID }
    func loadPeer(_ id: Int64, receive: @escaping @MainActor (Result<TelegramCallPeer, TelegramCallError>) -> Void) -> any TelegramCallRequest {
        peerReads.append(receive); return CallTestRequest()
    }
    func observeIncoming(receive: @escaping @MainActor (Result<[TelegramIncomingCall], TelegramCallError>) -> Void) -> any TelegramCallRequest {
        incoming = receive; return CallTestRequest()
    }
    func startOutgoing(basis: TelegramCallPeer, video: Bool, callID: UUID, receive: @escaping @MainActor (TelegramCallEvent) -> Bool) -> any TelegramCallLease {
        let lease = CallTestLease(); calls.append(.init(id: callID, receive: receive, lease: lease))
        if failDuringStart { _ = receive(.failed(.failed)) }; return lease
    }
    func accept(incoming: TelegramIncomingCall, video: Bool, receive: @escaping @MainActor (TelegramCallEvent) -> Bool) -> any TelegramCallLease {
        let lease = CallTestLease(); calls.append(.init(id: incoming.id, receive: receive, lease: lease)); return lease
    }
    func decline(incoming: TelegramIncomingCall) { declined.append(incoming.id) }
}
