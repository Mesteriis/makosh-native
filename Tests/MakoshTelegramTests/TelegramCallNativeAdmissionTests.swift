import XCTest
import TelegramCore
import TelegramApi
import Postbox
@testable import MakoshTelegram

final class TelegramCallNativeAdmissionTests: XCTestCase {
    func testFullUserCallFlagsAndBlockedPrivateStateGateBothKinds() throws {
        let allowed = try XCTUnwrap(telegramCallPeer(result: full(flags: (1 << 4) | (1 << 13)), accountID: 101, peerID: 42))
        XCTAssertTrue(allowed.canVoice); XCTAssertTrue(allowed.canVideo)
        for flags: Int32 in [1 << 0, 1 << 5] {
            let denied = try XCTUnwrap(telegramCallPeer(result: full(flags: flags | (1 << 4) | (1 << 13)), accountID: 101, peerID: 42))
            XCTAssertFalse(denied.canVoice); XCTAssertFalse(denied.canVideo)
        }
        let audio = try XCTUnwrap(telegramCallPeer(result: full(flags: 1 << 4), accountID: 101, peerID: 42))
        XCTAssertTrue(audio.canVoice); XCTAssertFalse(audio.canVideo); XCTAssertNotEqual(audio.revision, allowed.revision)
    }
    func testFullUserRefusesForeignOwnMissingMinAndDuplicateIdentities() {
        XCTAssertNil(telegramCallPeer(result: full(), accountID: 42, peerID: 42))
        XCTAssertNil(telegramCallPeer(result: full(), accountID: 101, peerID: 43))
        XCTAssertNil(telegramCallPeer(result: full(min: true), accountID: 101, peerID: 42))
        XCTAssertNil(telegramCallPeer(result: full(duplicate: true), accountID: 101, peerID: 42))
    }
    func testOnlyExactAuthenticatedActiveNativeSessionAdmitsMedia() throws {
        let id = UUID(), session = nativeSession(id: id)
        let configuration = try XCTUnwrap(TelegramCallMediaConfiguration(session: session, internalID: id, outgoing: true, video: true, proxy: nil))
        XCTAssertEqual(configuration.fingerprint, Data(repeating: 9, count: 32)); XCTAssertTrue(configuration.allowP2P)
        XCTAssertNil(TelegramCallMediaConfiguration(session: session, internalID: UUID(), outgoing: true, video: true, proxy: nil))
        XCTAssertNil(TelegramCallMediaConfiguration(session: session, internalID: id, outgoing: false, video: true, proxy: nil))
        for size in [0, 255, 257] {
            XCTAssertNil(TelegramCallMediaConfiguration(session: nativeSession(id: id, key: Data(repeating: 7, count: size)), internalID: id, outgoing: true, video: true, proxy: nil))
        }
        XCTAssertNil(TelegramCallMediaConfiguration(session: nativeSession(id: id, version: "unknown"), internalID: id, outgoing: true, video: true, proxy: nil))
        XCTAssertNil(TelegramCallMediaConfiguration(session: nativeSession(id: id, state: .requesting(ringing: true)), internalID: id, outgoing: true, video: true, proxy: nil))
    }
    func testProxyRequiresAdvertisedTCPRelayAndNeverEnablesP2P() throws {
        let id = UUID(); var draft = TelegramProxyDraft(); draft.host = "127.0.0.1"; draft.port = "1080"
        let proxy = try TelegramProxyServer(draft: draft)
        XCTAssertNil(TelegramCallMediaConfiguration(session: nativeSession(id: id), internalID: id, outgoing: true, video: true, proxy: proxy))
        let configuration = try XCTUnwrap(TelegramCallMediaConfiguration(session: nativeSession(id: id, tcp: true), internalID: id, outgoing: true, video: true, proxy: proxy))
        XCTAssertFalse(configuration.allowP2P); XCTAssertEqual(configuration.servers.count, 2)
        XCTAssertTrue(configuration.servers.allSatisfy(\.tcp))
        XCTAssertFalse(configuration.description.contains("synthetic-tag")); XCTAssertFalse(configuration.description.contains("127.0.0.1"))
    }
    func testOpaqueNativeCallAndReflectorNumbersArePreservedIncludingZero() throws {
        let id = UUID()
        let value = try XCTUnwrap(TelegramCallMediaConfiguration(session: nativeSession(id: id, opaqueID: 0, opaqueHash: 0, reflectorID: 0), internalID: id, outgoing: true, video: true, proxy: nil))
        XCTAssertEqual(value.servers.map(\.id), [1, 1]) // Native opaque number maps to a bounded local relay index.
    }
    func testMalformedEndpointAndKeyCannotReachNativeBackend() {
        let id = UUID()
        for port: Int32 in [0, -1, 65536] {
            XCTAssertNil(TelegramCallMediaConfiguration(session: nativeSession(id: id, port: port), internalID: id, outgoing: true, video: true, proxy: nil))
        }
        XCTAssertNil(TelegramCallMediaConfiguration(session: nativeSession(id: id, key: Data(count: 256)), internalID: id, outgoing: true, video: true, proxy: nil))
        XCTAssertNil(TelegramCallMediaConfiguration(session: nativeSession(id: id, tag: Data(count: 15)), internalID: id, outgoing: true, video: true, proxy: nil))
    }
    private func nativeSession(id: UUID, key: Data = Data(repeating: 7, count: 256), version: String = "5.0.0", tcp: Bool = false,
        port: Int32 = 443, tag: Data = Data(repeating: 3, count: 16), state: CallSessionState? = nil, opaqueID: Int64 = 101, opaqueHash: Int64 = 22, reflectorID: Int64 = -101) -> CallSession {
        .init(id: id, stableId: opaqueID, isOutgoing: true, type: .video, state: state ?? .active(id: .init(id: opaqueID, accessHash: opaqueHash),
            key: key, keyVisualHash: Data(repeating: 9, count: 32), connections: .init(primary: .reflector(.init(id: reflectorID,
                ip: "203.0.113.17", ipv6: "2001:db8::17", isTcp: tcp, port: port, peerTag: tag)), alternatives: []),
            maxLayer: 92, version: version, customParameters: nil, allowsP2P: true, supportsConferenceCalls: false), isVideoPossible: true)
    }
    private func full(flags: Int32 = 1 << 4, min: Bool = false, duplicate: Bool = false) -> Api.users.UserFull {
        telegramCallFullUserFixture(flags: flags, min: min, duplicate: duplicate)
    }
}
