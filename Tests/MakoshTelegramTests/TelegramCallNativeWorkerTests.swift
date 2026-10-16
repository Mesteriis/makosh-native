import XCTest
import CoreVideo
import CMakoshTelegramVoIP
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramCallNativeWorkerTests: XCTestCase {
    func testAllCEntryPointsRunOffMainActor() async throws {
        let fixture = CallWorkerFixture()
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: TelegramCallMediaInbox(deliver: { _ in }), functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        XCTAssertTrue(bridge.setMuted(true))
        await fulfillment(of: [fixture.muted], timeout: 2)
        XCTAssertTrue(bridge.setVideo(true))
        await fulfillment(of: [fixture.videoChanged], timeout: 2)
        XCTAssertTrue(bridge.receive(Data([1, 2])))
        await fulfillment(of: [fixture.signaled], timeout: 2)
        bridge.videoOutput(try frame())
        await fulfillment(of: [fixture.pushed], timeout: 2)
        bridge.stop()
        await fulfillment(of: [fixture.stopped], timeout: 2)
        fixture.release()
        await fulfillment(of: [fixture.destroyed], timeout: 2)
        XCTAssertEqual(fixture.calls, ["create", "mute", "video", "signal", "push", "stop", "destroy"])
        XCTAssertEqual(fixture.mainThreadCalls, [])
    }
    func testBlockedCreateKeepsAdmissionAndStopResponsive() async throws {
        let gate = DispatchSemaphore(value: 0), fixture = CallWorkerFixture(createGate: gate)
        defer { gate.signal() }
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: TelegramCallMediaInbox(deliver: { _ in }), functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        XCTAssertTrue(bridge.setMuted(true)); XCTAssertTrue(bridge.setVideo(true)); XCTAssertTrue(bridge.receive(Data([1])))
        bridge.videoOutput(try frame())
        bridge.stop()
        XCTAssertFalse(bridge.setMuted(false)); XCTAssertFalse(bridge.setVideo(false)); XCTAssertFalse(bridge.receive(Data([2])))
        gate.signal()
        await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertEqual(fixture.calls, ["create", "stop"])
        fixture.release()
        await fulfillment(of: [fixture.destroyed], timeout: 2)
    }
    func testBlockedCommandPreservesFIFOAndOnlyLatestWaitingFrame() async throws {
        let gate = DispatchSemaphore(value: 0), fixture = CallWorkerFixture(muteGate: gate)
        fixture.signaled.expectedFulfillmentCount = 2
        defer { gate.signal() }
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: TelegramCallMediaInbox(deliver: { _ in }), functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        XCTAssertTrue(bridge.setMuted(true))
        await fulfillment(of: [fixture.muted], timeout: 2)
        XCTAssertTrue(bridge.receive(Data([1]))); XCTAssertTrue(bridge.setVideo(true)); XCTAssertTrue(bridge.receive(Data([2])))
        bridge.videoOutput(try frame(2)); bridge.videoOutput(try frame(4)); bridge.videoOutput(try frame(6))
        gate.signal()
        await fulfillment(of: [fixture.signaled, fixture.videoChanged, fixture.pushed], timeout: 2)
        XCTAssertEqual(fixture.calls, ["create", "mute", "signal", "video", "signal", "push"])
        XCTAssertEqual(fixture.signals, [Data([1]), Data([2])]); XCTAssertEqual(fixture.widths, [6])
        bridge.stop(); await fulfillment(of: [fixture.stopped], timeout: 2)
        fixture.release(); await fulfillment(of: [fixture.destroyed], timeout: 2)
    }
    func testStopImmediatelyRevokesBlockedCommandQueuedWorkAndLateCallbacks() async throws {
        let gate = DispatchSemaphore(value: 0), fixture = CallWorkerFixture(muteGate: gate), output = CallWorkerOutput()
        defer { gate.signal() }
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        XCTAssertTrue(bridge.setMuted(true)); await fulfillment(of: [fixture.muted], timeout: 2)
        XCTAssertTrue(bridge.setVideo(true)); XCTAssertTrue(bridge.receive(Data([1])))
        bridge.videoOutput(try frame()); bridge.stop()
        fixture.emitState(2); fixture.emitSignaling()
        XCTAssertFalse(bridge.setMuted(false)); XCTAssertFalse(bridge.receive(Data([2])))
        XCTAssertEqual(output.states, []); XCTAssertEqual(output.signals, [])
        gate.signal(); await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertEqual(fixture.calls, ["create", "mute", "stop"])
        fixture.release(); await fulfillment(of: [fixture.destroyed, output.released], timeout: 2)
    }
    func testBlockedFrameDoesNotBlockStopOrAllowQueuedCommands() async throws {
        let gate = DispatchSemaphore(value: 0), fixture = CallWorkerFixture(pushGate: gate)
        defer { gate.signal() }
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: TelegramCallMediaInbox(deliver: { _ in }), functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        bridge.videoOutput(try frame(2)); await fulfillment(of: [fixture.pushed], timeout: 2)
        bridge.videoOutput(try frame(4)); bridge.videoOutput(try frame(6))
        XCTAssertTrue(bridge.setMuted(true)); bridge.stop()
        gate.signal(); await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertEqual(fixture.widths, [2]); XCTAssertEqual(fixture.calls, ["create", "push", "stop"])
        fixture.release(); await fulfillment(of: [fixture.destroyed], timeout: 2)
    }
    func testReleaseWaitsForBlockedStopAndDestroysOnce() async throws {
        let gate = DispatchSemaphore(value: 0), fixture = CallWorkerFixture(stopGate: gate), output = CallWorkerOutput()
        defer { gate.signal() }
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        bridge.stop(); bridge.stop(); await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertFalse(bridge.setVideo(true)); XCTAssertEqual(fixture.destroyCount, 0)
        fixture.release(); fixture.release()
        XCTAssertEqual(fixture.destroyCount, 0); XCTAssertEqual(output.releaseCount, 0)
        gate.signal(); await fulfillment(of: [fixture.destroyed, output.released], timeout: 2)
        XCTAssertEqual(fixture.calls, ["create", "stop", "destroy"]); XCTAssertEqual(output.releaseCount, 1)
    }
    func testStopBeforeWorkerStartsSkipsCreateAndReleasesInbox() async throws {
        let gate = DispatchSemaphore(value: 0), entered = expectation(description: "worker held"), queue = DispatchQueue(label: "Makosh.tests.call-worker")
        queue.async { entered.fulfill(); _ = gate.wait(timeout: .now() + 5) }
        await fulfillment(of: [entered], timeout: 2)
        defer { gate.signal() }
        let fixture = CallWorkerFixture(), output = CallWorkerOutput()
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions, nativeQueue: queue))
        bridge.stop(); gate.signal()
        await fulfillment(of: [output.released], timeout: 2)
        XCTAssertEqual(fixture.calls, []); XCTAssertEqual(output.states, [])
    }
    func testDeinitBeforeWorkerStartsSkipsCreateAndReleasesInbox() async throws {
        let gate = DispatchSemaphore(value: 0), entered = expectation(description: "worker held"), queue = DispatchQueue(label: "Makosh.tests.call-deinit")
        queue.async { entered.fulfill(); _ = gate.wait(timeout: .now() + 5) }
        await fulfillment(of: [entered], timeout: 2)
        defer { gate.signal() }
        let fixture = CallWorkerFixture(), output = CallWorkerOutput()
        var bridge: TelegramCallCBridge? = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions, nativeQueue: queue))
        XCTAssertNotNil(bridge); bridge = nil; gate.signal()
        await fulfillment(of: [output.released], timeout: 2)
        XCTAssertEqual(fixture.calls, [])
    }
    func testDeinitDuringCreateRetainsContextUntilActualRelease() async throws {
        let gate = DispatchSemaphore(value: 0), fixture = CallWorkerFixture(createGate: gate), output = CallWorkerOutput()
        defer { gate.signal() }
        var bridge: TelegramCallCBridge? = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions))
        weak var releasedBridge = bridge
        await fulfillment(of: [fixture.created], timeout: 2)
        bridge = nil; XCTAssertNil(releasedBridge); gate.signal()
        await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertEqual(fixture.destroyCount, 0); XCTAssertEqual(output.releaseCount, 0)
        fixture.emitState(2); fixture.emitSignaling()
        XCTAssertEqual(output.states, []); XCTAssertEqual(output.signals, [])
        fixture.release(); await fulfillment(of: [fixture.destroyed, output.released], timeout: 2)
        XCTAssertEqual(fixture.calls, ["create", "stop", "destroy"])
    }
    func testSynchronousNativeReleaseDuringStopWaitsForStopToReturn() async throws {
        let fixture = CallWorkerFixture(releaseDuringStop: true), output = CallWorkerOutput()
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        bridge.stop(); await fulfillment(of: [fixture.destroyed, output.released], timeout: 2)
        XCTAssertEqual(fixture.calls, ["create", "stop", "stop-returned", "destroy"])
        XCTAssertEqual(fixture.mainThreadCalls, []); XCTAssertEqual(output.releaseCount, 1)
    }
    func testCreateFailureReportsFailureAndReleasesWithoutDestroy() async throws {
        let fixture = CallWorkerFixture(createNil: true), output = CallWorkerOutput()
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions))
        await fulfillment(of: [output.failed, output.released], timeout: 2)
        XCTAssertFalse(bridge.setMuted(true)); XCTAssertFalse(bridge.receive(Data([1])))
        XCTAssertEqual(fixture.calls, ["create"]); XCTAssertEqual(output.states, [0]); XCTAssertEqual(output.releaseCount, 1)
    }
    func testControlBacklogRefusesOverflowAndReportsFailure() async throws {
        let gate = DispatchSemaphore(value: 0), fixture = CallWorkerFixture(createGate: gate), output = CallWorkerOutput()
        defer { gate.signal() }
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        for _ in 0..<32 { XCTAssertTrue(bridge.setMuted(true)) }
        XCTAssertFalse(bridge.setVideo(true)); XCTAssertFalse(bridge.setMuted(false))
        await fulfillment(of: [output.failed], timeout: 2)
        gate.signal(); await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertEqual(fixture.calls, ["create", "stop"])
        fixture.release(); await fulfillment(of: [fixture.destroyed, output.released], timeout: 2)
    }
    func testSignalingByteBacklogRefusesOverflowAndReportsFailure() async throws {
        let gate = DispatchSemaphore(value: 0), fixture = CallWorkerFixture(createGate: gate), output = CallWorkerOutput()
        defer { gate.signal() }
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        for _ in 0..<16 { XCTAssertTrue(bridge.receive(Data(repeating: 1, count: 65536))) }
        XCTAssertFalse(bridge.receive(Data([2])))
        await fulfillment(of: [output.failed], timeout: 2)
        gate.signal(); await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertEqual(fixture.calls, ["create", "stop"])
        fixture.release(); await fulfillment(of: [fixture.destroyed], timeout: 2)
    }
    func testSignalingPacketBacklogRefusesOverflowAndReportsFailure() async throws {
        let gate = DispatchSemaphore(value: 0), fixture = CallWorkerFixture(createGate: gate), output = CallWorkerOutput()
        defer { gate.signal() }
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        for _ in 0..<256 { XCTAssertTrue(bridge.receive(Data([1]))) }
        XCTAssertFalse(bridge.receive(Data([2])))
        await fulfillment(of: [output.failed], timeout: 2)
        gate.signal(); await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertEqual(fixture.calls, ["create", "stop"])
        fixture.release(); await fulfillment(of: [fixture.destroyed], timeout: 2)
    }
    func testAdmittedNativeFailureReportsFailureAndSkipsLaterWork() async throws {
        let gate = DispatchSemaphore(value: 0), fixture = CallWorkerFixture(muteGate: gate, muteResult: 0), output = CallWorkerOutput()
        defer { gate.signal() }
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        XCTAssertTrue(bridge.setMuted(true)); await fulfillment(of: [fixture.muted], timeout: 2)
        XCTAssertTrue(bridge.setVideo(true)); XCTAssertTrue(bridge.receive(Data([1])))
        gate.signal(); await fulfillment(of: [output.failed, fixture.stopped], timeout: 2)
        XCTAssertFalse(bridge.setMuted(false)); XCTAssertEqual(fixture.calls, ["create", "mute", "stop"])
        fixture.release(); await fulfillment(of: [fixture.destroyed], timeout: 2)
    }
    func testNativeVideoSignalingAndFrameRejectionsUseFailureInbox() async throws {
        for command in ["video", "signal", "push"] {
            let fixture = CallWorkerFixture(rejectedCommand: command), output = CallWorkerOutput()
            let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: output.inbox, functions: fixture.functions))
            await fulfillment(of: [fixture.created], timeout: 2)
            switch command {
            case "video": XCTAssertTrue(bridge.setVideo(true))
            case "signal": XCTAssertTrue(bridge.receive(Data([1])))
            default: bridge.videoOutput(try frame())
            }
            await fulfillment(of: [output.failed, fixture.stopped], timeout: 2)
            XCTAssertEqual(fixture.calls, ["create", command, "stop"]); XCTAssertEqual(output.states, [0])
            XCTAssertFalse(bridge.setMuted(true))
            fixture.release(); await fulfillment(of: [fixture.destroyed, output.released], timeout: 2)
        }
    }
    func testInvalidConfigurationRefusesBeforeSchedulingNativeCreate() throws {
        let fixture = CallWorkerFixture()
        var config = try configuration(); config.audioDevices = .init(inputUID: "invalid\0uid", outputUID: "")
        XCTAssertNil(TelegramCallCBridge(configuration: config, inbox: TelegramCallMediaInbox(deliver: { _ in }), functions: fixture.functions))
        XCTAssertEqual(fixture.calls, [])
    }
    func testFailedCreateThroughScheduledSessionRetiresOnce() async throws {
        let fixture = CallWorkerFixture(createNil: true), configuration = try configuration()
        let failed = expectation(description: "scheduled startup failure")
        failed.assertForOverFulfill = true
        var failures = 0
        let media = TelegramCallMediaSession(makeCore: { inbox in
            TelegramCallCBridge(configuration: configuration, inbox: inbox, functions: fixture.functions)
        }, makeCamera: { WorkerUnusedCamera() }, video: false, receive: { event in
            if case .failed = event { failures += 1; failed.fulfill() }
            return true
        })
        await fulfillment(of: [fixture.created, failed], timeout: 2)
        let retired = expectation(description: "failed startup retired")
        media.stop { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 2)
        XCTAssertEqual(failures, 1); XCTAssertEqual(fixture.destroyCount, 0)
    }
    func testUnsolicitedNativeReleaseThroughScheduledSessionFailsOnce() async throws {
        let fixture = CallWorkerFixture(), configuration = try configuration()
        let failed = expectation(description: "scheduled unexpected release")
        failed.assertForOverFulfill = true
        var failures = 0
        let media = TelegramCallMediaSession(makeCore: { inbox in
            TelegramCallCBridge(configuration: configuration, inbox: inbox, functions: fixture.functions)
        }, makeCamera: { WorkerUnusedCamera() }, video: false, receive: { event in
            if case .failed = event { failures += 1; failed.fulfill() }
            return true
        })
        await fulfillment(of: [fixture.created], timeout: 2)
        fixture.release()
        await fulfillment(of: [fixture.destroyed, failed], timeout: 2)
        let retired = expectation(description: "unexpected release retired")
        media.stop { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 2)
        XCTAssertEqual(failures, 1); XCTAssertEqual(fixture.destroyCount, 1)
    }
    private func configuration() throws -> TelegramCallMediaConfiguration {
        let id = UUID()
        return try XCTUnwrap(TelegramCallMediaConfiguration(session: .init(id: id, stableId: 11, isOutgoing: true, type: .audio,
            state: .active(id: .init(id: 11, accessHash: 12), key: Data(repeating: 7, count: 256), keyVisualHash: Data(repeating: 9, count: 32),
                connections: .init(primary: .reflector(.init(id: 21, ip: "203.0.113.17", ipv6: "2001:db8::17", isTcp: false, port: 443, peerTag: Data(repeating: 3, count: 16))), alternatives: []),
                maxLayer: 92, version: "5.0.0", customParameters: nil, allowsP2P: true, supportsConferenceCalls: false), isVideoPossible: true),
            internalID: id, outgoing: true, video: false, proxy: nil))
    }
    private func frame(_ width: Int = 4) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, 4, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &value), kCVReturnSuccess)
        return try XCTUnwrap(value)
    }
}

@MainActor private final class WorkerUnusedCamera: TelegramCallCameraSource {
    func start(output: @escaping @Sendable (CVPixelBuffer) -> Void, failure: @escaping @MainActor () -> Void) async -> Bool {
        XCTFail("Audio fixture must not start a camera"); return false
    }
    func stop(completed: @escaping @MainActor () -> Void) { completed() }
}

private final class CallWorkerOutput: @unchecked Sendable {
    let failed = XCTestExpectation(description: "native failure delivered")
    let released = XCTestExpectation(description: "native release delivered")
    private let lock = NSLock()
    private var savedStates: [Int32] = [], savedSignals: [Data] = [], savedReleases = 0
    var states: [Int32] { lock.withLock { savedStates } }
    var signals: [Data] { lock.withLock { savedSignals } }
    var releaseCount: Int { lock.withLock { savedReleases } }
    var inbox: TelegramCallMediaInbox { TelegramCallMediaInbox(schedule: { $0() }, deliver: { [self] value in
        switch value {
        case let .state(state): lock.withLock { savedStates.append(state) }; if state == 0 { failed.fulfill() }
        case let .signaling(data): lock.withLock { savedSignals.append(data) }
        case .released: lock.withLock { savedReleases += 1 }; released.fulfill()
        default: break
        }
    }) }
}
private final class CallWorkerFixture: @unchecked Sendable {
    let created = XCTestExpectation(description: "native create entered")
    let muted = XCTestExpectation(description: "native mute entered")
    let videoChanged = XCTestExpectation(description: "native video changed")
    let signaled = XCTestExpectation(description: "native signaling received")
    let pushed = XCTestExpectation(description: "native frame entered")
    let stopped = XCTestExpectation(description: "native stop entered")
    let destroyed = XCTestExpectation(description: "native destroyed")
    private let lock = NSLock()
    private let createGate: DispatchSemaphore?, muteGate: DispatchSemaphore?, pushGate: DispatchSemaphore?, stopGate: DispatchSemaphore?
    private let createNil: Bool, muteResult: Int32, rejectedCommand: String?, releaseDuringStop: Bool
    private var callbacks: MKCallCallbacks?
    private var recordedCalls: [String] = [], recordedMainThreadCalls: [String] = [], savedSignals: [Data] = [], savedWidths: [Int] = []
    init(createGate: DispatchSemaphore? = nil, muteGate: DispatchSemaphore? = nil, pushGate: DispatchSemaphore? = nil, stopGate: DispatchSemaphore? = nil,
         createNil: Bool = false, muteResult: Int32 = 1, rejectedCommand: String? = nil, releaseDuringStop: Bool = false) {
        self.createGate = createGate; self.muteGate = muteGate; self.pushGate = pushGate; self.stopGate = stopGate
        self.createNil = createNil; self.muteResult = muteResult; self.rejectedCommand = rejectedCommand; self.releaseDuringStop = releaseDuringStop
    }
    var calls: [String] { lock.withLock { recordedCalls } }
    var mainThreadCalls: [String] { lock.withLock { recordedMainThreadCalls } }
    var signals: [Data] { lock.withLock { savedSignals } }
    var widths: [Int] { lock.withLock { savedWidths } }
    var destroyCount: Int { lock.withLock { recordedCalls.filter { $0 == "destroy" }.count } }
    private func record(_ name: String) {
        lock.withLock { recordedCalls.append(name); if Thread.isMainThread { recordedMainThreadCalls.append(name) } }
    }
    private func wait(_ gate: DispatchSemaphore?) {
        if let gate { XCTAssertEqual(gate.wait(timeout: .now() + 5), .success) }
    }
    var functions: TelegramCallCFunctions {
        .init(create: { [self] _, callback in
            record("create"); lock.withLock { callbacks = callback.pointee }; created.fulfill(); wait(createGate)
            return createNil ? nil : OpaquePointer(bitPattern: 0x1234)
        }, signal: { [self] _, bytes, count in
            record("signal"); lock.withLock { savedSignals.append(Data(bytes: bytes!, count: count)) }; signaled.fulfill(); return rejectedCommand == "signal" ? 0 : 1
        }, mute: { [self] _, _ in record("mute"); muted.fulfill(); wait(muteGate); return muteResult },
        video: { [self] _, _ in record("video"); videoChanged.fulfill(); return rejectedCommand == "video" ? 0 : 1 },
        push: { [self] _, frame in record("push"); lock.withLock { savedWidths.append(CVPixelBufferGetWidth(frame)) }; pushed.fulfill(); wait(pushGate); return rejectedCommand == "push" ? 0 : 1 },
        stop: { [self] _ in
            record("stop"); stopped.fulfill(); wait(stopGate)
            if releaseDuringStop { release(); record("stop-returned") }
        },
        destroy: { [self] _ in record("destroy"); destroyed.fulfill() })
    }
    func release() { let value = lock.withLock { callbacks }; value?.released?(value?.context) }
    func emitState(_ state: Int32) { let value = lock.withLock { callbacks }; value?.state?(value?.context, state) }
    func emitSignaling() {
        let value = lock.withLock { callbacks }, data: [UInt8] = [17, 23, 41]
        data.withUnsafeBufferPointer { value?.signaling?(value?.context, $0.baseAddress, $0.count) }
    }
}
