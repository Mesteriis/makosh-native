import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class OrganizationRulesTests: XCTestCase {
    private let preferences = PersonsPreferences()

    func testPublicDomainsAreNotOrganizations() {
        XCTAssertTrue(OrganizationRules.isPublicDomain("gmail.com", extra: []))
        XCTAssertTrue(OrganizationRules.isPublicDomain("mail.gmail.com", extra: []), "subdomains of public domains are public")
        XCTAssertTrue(OrganizationRules.isPublicDomain("Yandex.RU", extra: []))
        XCTAssertTrue(OrganizationRules.isPublicDomain("corp.test", extra: ["corp.test"]))
        XCTAssertFalse(OrganizationRules.isPublicDomain("sidorov.ru", extra: []))
        XCTAssertEqual(OrganizationRules.domain(of: "Ivan@Sidorov.RU"), "sidorov.ru")
        XCTAssertNil(OrganizationRules.domain(of: "no-at-sign"))
    }

    func testDomainNeedsTwoAddresses() {
        let person = Person(displayName: "Иванов", emails: ["ivan@sidorov.ru"])
        XCTAssertTrue(
            OrganizationRules.suggestions(for: person, domainAddressCounts: ["sidorov.ru": 1], existing: [], preferences: preferences)
                .isEmpty)
        let suggestions = OrganizationRules.suggestions(
            for: person, domainAddressCounts: ["sidorov.ru": 2], existing: [], preferences: preferences)
        XCTAssertEqual(
            suggestions,
            [
                OrganizationSuggestion(
                    organizationName: "sidorov.ru", existingOrganizationID: nil, origin: .emailDomain("sidorov.ru"), role: "")
            ])
    }

    func testPublicDomainIsNeverSuggested() {
        let person = Person(displayName: "Иванов", emails: ["ivan@gmail.com"])
        XCTAssertTrue(
            OrganizationRules.suggestions(for: person, domainAddressCounts: ["gmail.com": 500], existing: [], preferences: preferences)
                .isEmpty)
    }

    func testCompanyFieldSuggestsExisting() {
        var organization = Person(displayName: "ип сидоров")
        organization.kind = .organization
        let person = Person(displayName: "Иванов", organization: " ИП Сидоров ", jobTitle: "Менеджер")
        let suggestions = OrganizationRules.suggestions(
            for: person, domainAddressCounts: [:], existing: [organization], preferences: preferences)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.organizationName, "ИП Сидоров")
        XCTAssertEqual(suggestions.first?.existingOrganizationID, organization.id)
        XCTAssertEqual(suggestions.first?.role, "Менеджер")
        if case .companyField = suggestions.first?.origin {} else { XCTFail("origin must be the company field") }
    }

    func testDomainSuggestionReusesExistingOrganizationNamedAfterDomain() {
        var organization = Person(displayName: "SIDOROV.RU")
        organization.kind = .organization
        let person = Person(displayName: "Иванов", emails: ["ivan@sidorov.ru", "ivan@gmail.com"])
        let suggestions = OrganizationRules.suggestions(
            for: person, domainAddressCounts: ["sidorov.ru": 3, "gmail.com": 1000], existing: [organization], preferences: preferences)
        XCTAssertEqual(suggestions.map(\.existingOrganizationID), [organization.id])
    }

    func testDisabledRulesReturnNothing() {
        var off = preferences
        off.domainRuleEnabled = false
        let person = Person(displayName: "Иванов", organization: "ИП Сидоров", emails: ["ivan@sidorov.ru"])
        let onlyCompany = OrganizationRules.suggestions(for: person, domainAddressCounts: ["sidorov.ru": 5], existing: [], preferences: off)
        XCTAssertEqual(onlyCompany.map(\.organizationName), ["ИП Сидоров"])
        off.companyRuleEnabled = false
        XCTAssertTrue(
            OrganizationRules.suggestions(for: person, domainAddressCounts: ["sidorov.ru": 5], existing: [], preferences: off).isEmpty)
    }

    func testOrganizationsThemselvesGetNoSuggestions() {
        var organization = Person(displayName: "ИП Сидоров", organization: "Холдинг", emails: ["info@sidorov.ru"])
        organization.kind = .organization
        XCTAssertTrue(
            OrganizationRules.suggestions(for: organization, domainAddressCounts: ["sidorov.ru": 5], existing: [], preferences: preferences)
                .isEmpty)
    }
}
