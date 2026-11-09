import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

final class OSINTDialogRulesTests: XCTestCase {
    private func ready() -> OSINTSettings {
        var settings = OSINTSettings(serverID: UUID())
        settings.enabled = true
        settings.host = "10.34.10.64"
        settings.login = "makosh"
        settings.hostKeyFingerprint = "SHA256:abc"
        settings.installedTag = "v1.2.13"
        settings.installedSHA = FlowsintPin.current.sha
        return settings
    }

    func testDisabledReasons() {
        let person = Person(displayName: "Анна")
        XCTAssertNil(OSINTDialogRules.disabledReason(settings: ready(), person: person))
        var off = ready()
        off.enabled = false
        XCTAssertEqual(OSINTDialogRules.disabledReason(settings: off, person: person), "Включите модуль в Настройках → Персоны")
        var unchecked = ready()
        unchecked.hostKeyFingerprint = nil
        XCTAssertEqual(OSINTDialogRules.disabledReason(settings: unchecked, person: person), "Проверьте соединение в Настройках → Персоны")
        var notInstalled = ready()
        notInstalled.installedSHA = nil
        XCTAssertEqual(OSINTDialogRules.disabledReason(settings: notInstalled, person: person), "Модуль не установлен")
        var deleted = person
        deleted.deletedAt = Date()
        XCTAssertEqual(OSINTDialogRules.disabledReason(settings: ready(), person: deleted), "Персона удалена или скрыта")
        var hidden = person
        hidden.hiddenAsSpam = true
        XCTAssertEqual(OSINTDialogRules.disabledReason(settings: ready(), person: hidden), "Персона удалена или скрыта")
    }

    func testDialogRulesDisableKeyedEnrichersWithoutKey() {
        let inputs = [OSINTInput(type: .email, value: "anna@example.test")]
        let rows = OSINTDialogRules.availableEnrichers(
            selected: [.emailToGravatar, .emailToBreaches], inputs: inputs, serverKeyNames: [])
        let breaches = rows.first { $0.enricher == .emailToBreaches }
        XCTAssertEqual(breaches?.enabled, false)
        XCTAssertEqual(breaches?.note, "нужен ключ HIBP_API_KEY")
        let gravatar = rows.first { $0.enricher == .emailToGravatar }
        XCTAssertEqual(gravatar?.enabled, true)
        XCTAssertNil(gravatar?.note)
        let keyed = OSINTDialogRules.availableEnrichers(
            selected: [.emailToBreaches], inputs: inputs, serverKeyNames: ["HIBP_API_KEY"])
        XCTAssertEqual(keyed.first?.enabled, true)
    }

    func testIncompatibleEnrichersHidden() {
        let inputs = [OSINTInput(type: .email, value: "anna@example.test")]
        let rows = OSINTDialogRules.availableEnrichers(
            selected: [.emailToGravatar, .phoneToHudsonRock, .usernameToMaigret], inputs: inputs, serverKeyNames: [])
        XCTAssertEqual(rows.map(\.enricher), [.emailToGravatar])
    }

    func testCanLaunchNeedsValueAndEnricher() {
        let input = OSINTInput(type: .email, value: "anna@example.test")
        XCTAssertFalse(OSINTDialogRules.canLaunch(inputs: [], enrichers: [.emailToGravatar]))
        XCTAssertFalse(OSINTDialogRules.canLaunch(inputs: [input], enrichers: []))
        XCTAssertFalse(OSINTDialogRules.canLaunch(inputs: [input], enrichers: [.phoneToHudsonRock]))
        XCTAssertTrue(OSINTDialogRules.canLaunch(inputs: [input], enrichers: [.emailToGravatar]))
    }

    func testDisclosureNamesHostAndServices() {
        let text = OSINTDialogRules.disclosure(host: "10.34.10.64", enrichers: [.emailToGravatar, .emailToBreaches, .usernameToMaigret])
        XCTAssertTrue(text.contains("10.34.10.64"))
        XCTAssertTrue(text.contains("Gravatar"))
        XCTAssertTrue(text.contains("Have I Been Pwned"))
        XCTAssertTrue(text.contains("Maigret"))
        XCTAssertFalse(text.contains("Veriphone"))
        XCTAssertFalse(text.contains("Whoxy"))
        let phones = OSINTDialogRules.disclosure(host: "h", enrichers: [.phoneToCarrier, .orgToDomains, .emailToHudsonRock])
        XCTAssertTrue(phones.contains("Veriphone"))
        XCTAssertTrue(phones.contains("Whoxy"))
        XCTAssertTrue(phones.contains("HudsonRock"))
    }

    func testDisclosureCarriesResponsibilityLine() {
        let text = OSINTDialogRules.disclosure(host: "10.34.10.64", enrichers: [.emailToGravatar])
        XCTAssertTrue(text.contains("Ответственность"), text)
        XCTAssertTrue(OSINTDialogRules.responsibility.contains("условий"), OSINTDialogRules.responsibility)
    }

    func testEnrichersMissingOnServerAreHidden() {
        let inputs = [OSINTInput(type: .email, value: "anna@example.test"), OSINTInput(type: .phone, value: "+79990000000")]
        let offered: Set<String> = ["email_to_gravatar", "phone_to_carrier"]
        let rows = OSINTDialogRules.availableEnrichers(
            selected: [.emailToGravatar, .phoneToHudsonRock, .phoneToCarrier], inputs: inputs, serverKeyNames: [],
            serverEnricherNames: offered)
        XCTAssertEqual(Set(rows.map(\.enricher)), [.emailToGravatar, .phoneToCarrier], "phone_to_device_hudsonrock is not on this server")
        let unknown = OSINTDialogRules.availableEnrichers(
            selected: [.emailToGravatar, .phoneToHudsonRock], inputs: inputs, serverKeyNames: [], serverEnricherNames: nil)
        XCTAssertTrue(unknown.contains { $0.enricher == .phoneToHudsonRock }, "an unknown server list hides nothing")
    }

    func testDisclosureNamesNewServices() {
        let text = OSINTDialogRules.disclosure(
            host: "h", enrichers: [.usernameToSherlock, .emailToDehashed, .orgToASN, .domainToWhois, .phoneToHudsonRock])
        for name in ["Sherlock", "DeHashed", "ProjectDiscovery", "WHOIS", "HudsonRock"] { XCTAssertTrue(text.contains(name), name) }
    }
}
