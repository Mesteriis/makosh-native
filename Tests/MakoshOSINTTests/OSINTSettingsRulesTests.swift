import Foundation
import XCTest

@testable import MakoshOSINT

final class OSINTSettingsRulesTests: XCTestCase {
    private func configured() -> OSINTSettings {
        var settings = OSINTSettings(serverID: UUID())
        settings.enabled = true
        settings.host = "10.34.10.64"
        settings.login = "makosh"
        settings.hostKeyFingerprint = "SHA256:abc"
        return settings
    }

    func testStatusTexts() {
        let empty = OSINTSettings(serverID: UUID())
        XCTAssertTrue(OSINTSettingsRules.status(empty, connected: false).lowercased().contains("не настроен"))
        var unchecked = configured()
        unchecked.hostKeyFingerprint = nil
        XCTAssertTrue(OSINTSettingsRules.status(unchecked, connected: false).lowercased().contains("проверьте соединение"))
        let checked = configured()
        XCTAssertTrue(OSINTSettingsRules.status(checked, connected: true).lowercased().contains("не установлен"))
        var installed = configured()
        installed.installedTag = "v1.2.13"
        installed.installedSHA = FlowsintPin.current.sha
        XCTAssertTrue(OSINTSettingsRules.status(installed, connected: true).lowercased().contains("установлен v1.2.13"))
        let offline = OSINTSettingsRules.status(installed, connected: false).lowercased()
        XCTAssertTrue(offline.contains("v1.2.13"))
        XCTAssertTrue(offline.contains("не отвечает"))
    }

    func testSettingsRulesAfterHostChange() {
        XCTAssertTrue(OSINTSettingsRules.canInstall(configured()))
        var changed = configured()
        changed.hostKeyFingerprint = nil
        XCTAssertFalse(OSINTSettingsRules.canInstall(changed))
        var disabled = configured()
        disabled.enabled = false
        XCTAssertFalse(OSINTSettingsRules.canInstall(disabled))
        var noLogin = configured()
        noLogin.login = " "
        XCTAssertFalse(OSINTSettingsRules.canInstall(noLogin))
    }

    func testInstallButtonTitles() {
        let pin = FlowsintPin.current
        XCTAssertEqual(OSINTSettingsRules.installButtonTitle(configured(), pin: pin), "Развернуть модуль")
        var older = configured()
        older.installedTag = "v1.2.9"
        older.installedSHA = "0000000000000000000000000000000000000000"
        XCTAssertEqual(OSINTSettingsRules.installButtonTitle(older, pin: pin), "Обновить до v1.2.13")
        var same = configured()
        same.installedTag = pin.tag
        same.installedSHA = pin.sha
        XCTAssertEqual(OSINTSettingsRules.installButtonTitle(same, pin: pin), "Переустановить v1.2.13")
    }

    func testKeyState() {
        XCTAssertEqual(OSINTSettingsRules.keyState(name: "HIBP_API_KEY", serverKeyNames: ["HIBP_API_KEY"]), "задан")
        XCTAssertEqual(OSINTSettingsRules.keyState(name: "WHOXY_API_KEY", serverKeyNames: ["HIBP_API_KEY"]), "не задан")
    }
}
