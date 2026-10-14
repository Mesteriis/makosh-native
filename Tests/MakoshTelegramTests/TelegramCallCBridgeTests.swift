import XCTest
import CMakoshTelegramVoIP
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramCallCBridgeTests: XCTestCase {
    func testCABIReceivesCompleteNativeKeyVersionAndBothRelayAddresses() throws {
        let fixture = CallCFixture(), output = CallCOutput()
        let inbox = TelegramCallMediaInbox(deliver: output.append)
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: inbox, functions: fixture.functions))
        XCTAssertEqual(fixture.version, "5.0.0"); XCTAssertEqual(fixture.key, Data(repeating: 7, count: 256))
        XCTAssertEqual(fixture.hosts, ["203.0.113.17", "2001:db8::17"])
        XCTAssertEqual(fixture.outgoing, 1); XCTAssertEqual(fixture.p2p, 1)
        XCTAssertTrue(bridge.setMuted(true)); XCTAssertEqual(fixture.mutes, [1])
        XCTAssertTrue(bridge.receive(Data([1, 2, 3]))); XCTAssertEqual(fixture.signals, [Data([1, 2, 3])])
        bridge.stop(); fixture.release()
    }
    func testStopRevokesControlsAndNativeReleaseDestroysHandleOnce() async throws {
        let fixture = CallCFixture(), output = CallCOutput()
        let inbox = TelegramCallMediaInbox(deliver: output.append)
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: inbox, functions: fixture.functions))
        bridge.stop(); bridge.stop()
        XCTAssertEqual(fixture.stops, 1); XCTAssertEqual(fixture.destroyed, 0)
        XCTAssertFalse(bridge.setMuted(false)); XCTAssertFalse(bridge.setVideo(true)); XCTAssertFalse(bridge.receive(Data([1])))
        fixture.release()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(fixture.destroyed, 1); XCTAssertEqual(output.released, 1)
    }
    func testNativeCallbackCopiesBorrowedSignalingBeforeReturning() async throws {
        let fixture = CallCFixture(), output = CallCOutput()
        let bridge = try XCTUnwrap(TelegramCallCBridge(configuration: configuration(), inbox: TelegramCallMediaInbox(deliver: output.append), functions: fixture.functions))
        fixture.emitSignaling()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(output.signals, [Data([17, 23, 41])])
        bridge.stop(); fixture.release()
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
    private let lock = NSLock()
    private var packets: [Data] = [], releases = 0
    var signals: [Data] { lock.withLock { packets } }
    var released: Int { lock.withLock { releases } }
    func append(_ value: TelegramCallMediaDelivery) {
        lock.withLock { switch value { case let .signaling(data): packets.append(data); case .released: releases += 1; default: break } }
    }
}
private final class CallCFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks: MKCallCallbacks?
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
                savedVersion = withUnsafeBytes(of: config.pointee.version) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
                savedKey = withUnsafeBytes(of: config.pointee.key) { Data($0) }
                savedOutgoing = config.pointee.outgoing; savedP2P = config.pointee.allow_p2p
                for index in 0..<config.pointee.server_count {
                    savedHosts.append(withUnsafeBytes(of: config.pointee.servers[index].host) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) })
                }
            }
            return OpaquePointer(bitPattern: 0x1234)
        }, signal: { [self] _, data, size in lock.withLock { savedSignals.append(Data(bytes: data!, count: size)) }; return 1 },
        mute: { [self] _, value in lock.withLock { savedMutes.append(value) }; return 1 }, video: { _, _ in 1 }, push: { _, _ in 1 },
        stop: { [self] _ in lock.withLock { stopCount += 1 } }, destroy: { [self] _ in lock.withLock { destroyCount += 1 } })
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
