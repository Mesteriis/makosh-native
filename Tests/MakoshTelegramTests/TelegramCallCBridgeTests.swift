import XCTest
import CMakoshTelegramVoIP
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramCallCBridgeTests: XCTestCase {
    func testExplicitAudioUIDsAreCopiedIntoVersionedCConfiguration() async throws {
        let fixture = CallCFixture()
        var config = try configuration(); config.audioDevices = .init(inputUID: "qa-input", outputUID: "qa-output")
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: config, inbox: TelegramCallMediaInbox(deliver: { _ in }), functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        XCTAssertEqual(fixture.audioUIDs, ["qa-input", "qa-output"])
        XCTAssertEqual(fixture.abiVersion, 2)
        bridge.stop(); await fulfillment(of: [fixture.stopped], timeout: 2)
        fixture.release(); await fulfillment(of: [fixture.destroyedEvent], timeout: 2)
    }
    func testCABIReceivesCompleteNativeKeyVersionAndBothRelayAddresses() async throws {
        let fixture = CallCFixture(), output = CallCOutput()
        let inbox = TelegramCallMediaInbox(deliver: output.append)
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: inbox, functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        XCTAssertEqual(fixture.version, "5.0.0"); XCTAssertEqual(fixture.key, Data(repeating: 7, count: 256))
        XCTAssertEqual(fixture.hosts, ["203.0.113.17", "2001:db8::17"])
        XCTAssertEqual(fixture.outgoing, 1); XCTAssertEqual(fixture.p2p, 1)
        XCTAssertTrue(bridge.setMuted(true)); await fulfillment(of: [fixture.muted], timeout: 2); XCTAssertEqual(fixture.mutes, [1])
        XCTAssertTrue(bridge.receive(Data([1, 2, 3]))); await fulfillment(of: [fixture.signaled], timeout: 2); XCTAssertEqual(fixture.signals, [Data([1, 2, 3])])
        bridge.stop(); await fulfillment(of: [fixture.stopped], timeout: 2)
        fixture.release(); await fulfillment(of: [fixture.destroyedEvent, output.releasedEvent], timeout: 2)
    }
    func testStopRevokesControlsAndNativeReleaseDestroysHandleOnce() async throws {
        let fixture = CallCFixture(), output = CallCOutput()
        let inbox = TelegramCallMediaInbox(deliver: output.append)
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: inbox, functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        bridge.stop(); bridge.stop()
        await fulfillment(of: [fixture.stopped], timeout: 2)
        XCTAssertEqual(fixture.stops, 1); XCTAssertEqual(fixture.destroyed, 0)
        XCTAssertFalse(bridge.setMuted(false)); XCTAssertFalse(bridge.setVideo(true)); XCTAssertFalse(bridge.receive(Data([1])))
        fixture.release()
        await fulfillment(of: [fixture.destroyedEvent, output.releasedEvent], timeout: 2)
        XCTAssertEqual(fixture.destroyed, 1); XCTAssertEqual(output.released, 1)
    }
    func testNativeCallbackCopiesBorrowedSignalingBeforeReturning() async throws {
        let fixture = CallCFixture(), output = CallCOutput()
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: TelegramCallMediaInbox(deliver: output.append), functions: fixture.functions))
        await fulfillment(of: [fixture.created], timeout: 2)
        fixture.emitSignaling()
        await fulfillment(of: [output.signaled], timeout: 2)
        XCTAssertEqual(output.signals, [Data([17, 23, 41])])
        bridge.stop(); await fulfillment(of: [fixture.stopped], timeout: 2)
        fixture.release(); await fulfillment(of: [fixture.destroyedEvent, output.releasedEvent], timeout: 2)
    }
    private func configuration() throws -> TelegramCallMediaConfiguration {
        let id = UUID()
        return try XCTUnwrap(TelegramCallMediaConfiguration(session: .init(id: id, stableId: 11, isOutgoing: true, type: .audio,
            state: .active(id: .init(id: 11, accessHash: 12), key: Data(repeating: 7, count: 256), keyVisualHash: Data(repeating: 9, count: 32),
                connections: .init(primary: .reflector(.init(id: 21, ip: "203.0.113.17", ipv6: "2001:db8::17", isTcp: false, port: 443, peerTag: Data(repeating: 3, count: 16))), alternatives: []),
                maxLayer: 92, version: "5.0.0", customParameters: nil, allowsP2P: true, supportsConferenceCalls: false), isVideoPossible: true),
            internalID: id, outgoing: true, video: false, proxy: nil))
    }
}
private final class CallCOutput: @unchecked Sendable {
    let signaled = XCTestExpectation(description: "borrowed signaling delivered")
    let releasedEvent = XCTestExpectation(description: "native release delivered")
    private let lock = NSLock()
    private var packets: [Data] = [], releases = 0
    var signals: [Data] { lock.withLock { packets } }
    var released: Int { lock.withLock { releases } }
    func append(_ value: TelegramCallMediaDelivery) {
        lock.withLock { switch value { case let .signaling(data): packets.append(data); case .released: releases += 1; default: break } }
        switch value { case .signaling: signaled.fulfill(); case .released: releasedEvent.fulfill(); default: break }
    }
}
private final class CallCFixture: @unchecked Sendable {
    let created = XCTestExpectation(description: "native created")
    let muted = XCTestExpectation(description: "native muted")
    let signaled = XCTestExpectation(description: "native signaling received")
    let stopped = XCTestExpectation(description: "native stopped")
    let destroyedEvent = XCTestExpectation(description: "native destroyed")
    private let lock = NSLock()
    private var callbacks: MKCallCallbacks?
    private var savedAudioUIDs: [String] = [], savedABIVersion: UInt32 = 0
    var audioUIDs: [String] { lock.withLock { savedAudioUIDs } }
    var abiVersion: UInt32 { lock.withLock { savedABIVersion } }
    private var savedVersion = "", savedKey = Data(), savedHosts: [String] = [], savedMutes: [Int32] = [], savedSignals: [Data] = []
    private var savedOutgoing: UInt8 = 0, savedP2P: UInt8 = 0, stopCount = 0, destroyCount = 0
    var version: String { lock.withLock { savedVersion } }
    var key: Data { lock.withLock { savedKey } }
    var hosts: [String] { lock.withLock { savedHosts } }
    var mutes: [Int32] { lock.withLock { savedMutes } }
    var signals: [Data] { lock.withLock { savedSignals } }
    var outgoing: UInt8 { lock.withLock { savedOutgoing } }
    var p2p: UInt8 { lock.withLock { savedP2P } }
    var stops: Int { lock.withLock { stopCount } }
    var destroyed: Int { lock.withLock { destroyCount } }
    var functions: TelegramCallCFunctions {
        .init(create: { [self] config, callback in
            lock.withLock {
                callbacks = callback.pointee
                savedABIVersion = config.pointee.abi_version
                savedAudioUIDs = [withUnsafeBytes(of: config.pointee.audio_input_uid) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }, withUnsafeBytes(of: config.pointee.audio_output_uid) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }]
                savedVersion = withUnsafeBytes(of: config.pointee.version) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
                savedKey = withUnsafeBytes(of: config.pointee.key) { Data($0) }
                savedOutgoing = config.pointee.outgoing; savedP2P = config.pointee.allow_p2p
                for index in 0..<config.pointee.server_count {
                    savedHosts.append(withUnsafeBytes(of: config.pointee.servers[index].host) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) })
                }
            }
            created.fulfill(); return OpaquePointer(bitPattern: 0x1234)
        }, signal: { [self] _, data, size in lock.withLock { savedSignals.append(Data(bytes: data!, count: size)) }; signaled.fulfill(); return 1 },
        mute: { [self] _, value in lock.withLock { savedMutes.append(value) }; muted.fulfill(); return 1 }, video: { _, _ in 1 }, push: { _, _ in 1 },
        stop: { [self] _ in lock.withLock { stopCount += 1 }; stopped.fulfill() },
        destroy: { [self] _ in lock.withLock { destroyCount += 1 }; destroyedEvent.fulfill() })
    }
    func release() { let value = lock.withLock { callbacks }; value?.released?(value?.context) }
    func emitSignaling() {
        let value = lock.withLock { callbacks }; var data: [UInt8] = [17, 23, 41]
        data.withUnsafeMutableBufferPointer { buffer in
            value?.signaling?(value?.context, buffer.baseAddress, buffer.count)
            for index in buffer.indices { buffer[index] = 0 }
        }
    }
}
