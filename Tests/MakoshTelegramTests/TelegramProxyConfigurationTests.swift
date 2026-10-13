import XCTest
import TelegramCore
@testable import MakoshTelegram

private nonisolated func socksDraft() -> TelegramProxyDraft {
    var d = TelegramProxyDraft(); d.host = " Proxy.Example.Invalid "; d.port = "1080"
    d.username = "SyntheticUser"; d.password = "SyntheticPassword"; return d
}
final class TelegramProxyConfigurationTests: XCTestCase {
    func testValidSOCKSIsNormalizedAndCredentialsReachOnlyActiveNativeConfiguration() throws {
        let server = try TelegramProxyServer(draft: socksDraft())
        var c = TelegramProxyConfiguration(); c.servers = [server]; c.selected = server.id; c.enabled = true
        let native = try c.native()
        XCTAssertEqual(native.activeServer?.host, "proxy.example.invalid"); XCTAssertEqual(native.activeServer?.port, 1080)
        guard case let .socks5(username, password)? = native.activeServer?.connection else { return XCTFail("Expected SOCKS5") }
        XCTAssertEqual(username, "SyntheticUser"); XCTAssertEqual(password, "SyntheticPassword")
        XCTAssertFalse(String(describing: server).contains("SyntheticPassword")); XCTAssertFalse(String(reflecting: server).contains("SyntheticUser"))
        c.enabled = false
        let disabled = try c.native(); XCTAssertFalse(disabled.enabled); XCTAssertNil(disabled.activeServer)
        XCTAssertTrue(disabled.servers.isEmpty)
    }
    func testMTProtoSecretUsesNativeParserWithoutTruncationOrDirectFallback() throws {
        var d = TelegramProxyDraft(); d.kind = .mtproto; d.host = "127.0.0.1"; d.port = "443"
        d.secret = "dd" + String(repeating: "12", count: 16)
        let server = try TelegramProxyServer(draft: d)
        var c = TelegramProxyConfiguration(); c.servers = [server]; c.selected = server.id; c.enabled = true
        let native = try c.native()
        guard case let .mtp(secret)? = native.activeServer?.connection else { return XCTFail("Expected MTProto") }
        XCTAssertEqual(secret, Data([0xdd] + Array(repeating: 0x12, count: 16)))
        for secret in ["", "123", String(repeating: "x", count: 32), String(repeating: "a", count: 1025)] {
            d.secret = secret; XCTAssertThrowsError(try TelegramProxyServer(draft: d))
        }
    }
    func testURLCredentialsControlsInvalidPortsAndOverlongSOCKSFieldsAreRejected() {
        for host in ["", "https://proxy.example.invalid", "user@host", "host/path", "host:443", "127.1", "bad..host", "host\u{0000}",
            "127.0.0.1\u{0000}suffix", "::1\u{0000}suffix", "[::1\u{0000}suffix]"] {
            var d = socksDraft(); d.host = host; XCTAssertThrowsError(try TelegramProxyServer(draft: d), host)
        }
        for port in ["0", "65536", "-1", "+443", "１２３", "443x"] {
            var d = socksDraft(); d.port = port; XCTAssertThrowsError(try TelegramProxyServer(draft: d), port)
        }
        var d = socksDraft(); d.username = String(repeating: "я", count: 128)
        XCTAssertThrowsError(try TelegramProxyServer(draft: d))
        d = socksDraft(); d.username = ""; XCTAssertThrowsError(try TelegramProxyServer(draft: d))
    }
    func testIPv6AndUnauthenticatedSOCKSRemainSupported() throws {
        var d = TelegramProxyDraft(); d.host = "[::1]"; d.port = "9050"
        let server = try TelegramProxyServer(draft: d)
        var c = TelegramProxyConfiguration(); c.servers = [server]; c.selected = server.id; c.enabled = true
        let native = try c.native(); XCTAssertEqual(native.activeServer?.host, "::1")
        guard case let .socks5(username, password)? = native.activeServer?.connection else { return XCTFail("Expected SOCKS5") }
        XCTAssertNil(username); XCTAssertNil(password)
    }
    func testMissingSelectedServerDuplicateIdentityOrCorruptStoredPortCannotConnectDirectly() throws {
        let server = try TelegramProxyServer(draft: socksDraft())
        var c = TelegramProxyConfiguration(); c.servers = [server]; c.enabled = true
        XCTAssertThrowsError(try c.native())
        c.selected = UUID(); XCTAssertThrowsError(try c.native())
        c.selected = server.id; c.servers = [server,server]; XCTAssertThrowsError(try c.native())
        c.servers = [server]
        let encoded = try JSONEncoder().encode(c)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var servers = try XCTUnwrap(object["servers"] as? [[String: Any]])
        servers[0]["port"] = 0; object["servers"] = servers
        let corrupt = try JSONDecoder().decode(TelegramProxyConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try corrupt.native())
    }
}
