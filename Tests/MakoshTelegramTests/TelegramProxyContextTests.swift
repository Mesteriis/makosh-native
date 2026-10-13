import XCTest
import TelegramCore
import MtProtoKit
import OpenSSLEncryption
@testable import MakoshTelegram

@MainActor final class TelegramProxyContextTests: XCTestCase {
    private func context() -> MTContext {
        // No MTProto, account, transport, keychain or datacenter actions are created.
        MTContext(serialization: Serialization(), encryptionProvider: OpenSSLEncryptionProvider(),
            apiEnvironment: MTApiEnvironment(deviceModelName: "Synthetic"), isTestingEnvironment: true, useTempAuthKeys: false)
    }
    private func configuration() throws -> TelegramProxyConfiguration {
        var d = TelegramProxyDraft(); d.host = "127.0.0.1"; d.port = "9050"
        d.username = "SyntheticUser"; d.password = "SyntheticPassword"
        let server = try TelegramProxyServer(draft: d)
        var c = TelegramProxyConfiguration(); c.servers = [server]; c.selected = server.id; c.enabled = true; return c
    }
    func testActualNativeContextHasSelectedProxyBeforeAcknowledgementAndExplicitDisableClearsIt() async throws {
        let context = context(); var c = try configuration()
        let applied = try await telegramDataValue(telegramApplyProxy(context: context, configuration: c), test: self)
        XCTAssertTrue(applied)
        XCTAssertEqual(context.apiEnvironment.socksProxySettings?.ip, "127.0.0.1")
        XCTAssertEqual(context.apiEnvironment.socksProxySettings?.port, 9050)
        XCTAssertEqual(context.apiEnvironment.socksProxySettings?.password, "SyntheticPassword")
        c.enabled = false
        let disabled = try await telegramDataValue(telegramApplyProxy(context: context, configuration: c), test: self)
        XCTAssertTrue(disabled); XCTAssertNil(context.apiEnvironment.socksProxySettings)
    }
    func testInvalidSelectedProxyCannotReplaceExistingRouteWithDirectConnection() async throws {
        let context = context(), c = try configuration()
        let applied = try await telegramDataValue(telegramApplyProxy(context: context, configuration: c), test: self)
        XCTAssertTrue(applied)
        var invalid = c; invalid.selected = nil
        let result = try await telegramDataValue(telegramApplyProxy(context: context, configuration: invalid), test: self)
        XCTAssertFalse(result); XCTAssertEqual(context.apiEnvironment.socksProxySettings?.ip, "127.0.0.1")
    }
}
