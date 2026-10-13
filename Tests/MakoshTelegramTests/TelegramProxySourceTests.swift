import XCTest
import TelegramCore
import SwiftSignalKit

@MainActor final class TelegramProxySourceTests: XCTestCase {
    private func settings(host: String) -> ProxySettings {
        let server = ProxyServerSettings(host: host, port: 1080, connection: .socks5(username: nil, password: nil))
        return .init(enabled: true, servers: [server], activeServer: server, useForCalls: false)
    }
    func testNewNetworkReadsLatestExternalSnapshotInsteadOfEarlierStoredProxy() async throws {
        let external = ValuePromise<ProxySettings>(.defaultSettings)
        external.set(settings(host: "new.example.invalid"))
        let value = try await telegramDataValue(makoshInitialProxySettings(stored: settings(host: "old.example.invalid"),
            external: external.get()), test: self)
        XCTAssertEqual(value?.activeServer?.host, "new.example.invalid")
        let disabled = try await telegramDataValue(makoshInitialProxySettings(stored: settings(host: "old.example.invalid"),
            external: .single(.defaultSettings)), test: self)
        XCTAssertFalse(disabled?.enabled ?? true); XCTAssertNil(disabled?.activeServer)
    }
    func testExternalUpdatesNeverSubscribeToStoredCredentialsAndExplicitDisableIsEmitted() async {
        let external = ValuePromise<ProxySettings>(.defaultSettings), done = expectation(description: "External proxy updates")
        done.expectedFulfillmentCount = 3
        var storedStarted = false, values: [String?] = []
        let stored = Signal<ProxySettings?, NoError> { subscriber in
            storedStarted = true; subscriber.putNext(self.settings(host: "stored.example.invalid")); subscriber.putCompletion()
            return EmptyDisposable
        }
        let d = (makoshProxySettingsSource(external: external.get(), stored: stored) |> deliverOnMainQueue).start(next: {
            values.append($0?.host); done.fulfill()
        })
        defer { d.dispose() }
        external.set(settings(host: "selected.example.invalid")); external.set(.defaultSettings)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(values, [nil,"selected.example.invalid",nil]); XCTAssertFalse(storedStarted)
    }
    func testAbsentExternalSourcePreservesLegacyEngineBehavior() async throws {
        let value = try await telegramDataValue(makoshInitialProxySettings(stored: settings(host: "legacy.example.invalid"), external: nil), test: self)
        XCTAssertEqual(value?.activeServer?.host, "legacy.example.invalid")
    }
}
