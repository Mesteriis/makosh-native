import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

final class OSINTCardGroupingTests: XCTestCase {
    private let server = UUID()
    private func observation(
        _ field: String, _ value: String, status: ObservationStatus = .proposed, service: String = "osint"
    ) -> Observation {
        Observation(
            field: field, value: value,
            source: SourceStamp(
                identity: ServiceIdentity(service: service, accountID: server.uuidString, externalID: "sk-1"),
                fetchedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            status: status)
    }

    func testGroupsByFieldPrefix() {
        var person = Person(displayName: "Анна")
        person.observations = [
            observation("emails", "anna.k@example.test"), observation("phones", "+79990000001"), observation("usernames", "anna_k"),
            observation("social.github", "https://github.com/anna_k"), observation("breach", "Adobe, 2013-10-04"),
            observation("phone.info", "+79990000000 — RU, МТС, mobile"), observation("domain", "example.test"),
            observation("avatar", "https://www.gravatar.com/avatar/h"), observation("organization.suggested", "Example LLC"),
        ]
        let items = OSINTCardGrouping.items(for: person)
        XCTAssertEqual(items.count, 9)
        let groups = Dictionary(grouping: items, by: \.group).mapValues { $0.count }
        XCTAssertEqual(groups[.contacts], 3)
        XCTAssertEqual(groups[.social], 1)
        XCTAssertEqual(groups[.breaches], 1)
        XCTAssertEqual(groups[.phone], 1)
        XCTAssertEqual(groups[.domains], 1)
        XCTAssertEqual(groups[.avatar], 1)
        XCTAssertEqual(groups[.organizations], 1)
        XCTAssertEqual(items.first { $0.group == .social }?.title, "GitHub")
        XCTAssertEqual(OSINTCardGroup.contacts.title, "Адреса и телефоны")
        XCTAssertEqual(
            OSINTCardGroup.allCases.map(\.title), ["Адреса и телефоны", "Соцсети", "Утечки", "Телефон", "Домены", "Аватар", "Организации"])
    }

    func testRejectedAndForeignObservationsExcluded() {
        var person = Person(displayName: "Анна")
        person.observations = [
            observation("usernames", "anna_k", status: .proposed), observation("usernames", "rejected_one", status: .rejected),
            observation("social.github", "https://github.com/anna_k", status: .confirmed),
            observation("emails", "from-mail@example.test", status: .observed, service: "mail"),
            observation("usernames", "ai_proposal", status: .proposed, service: "ai"),
        ]
        let items = OSINTCardGrouping.items(for: person)
        XCTAssertEqual(items.map(\.value), ["anna_k", "https://github.com/anna_k"])
        XCTAssertEqual(items.map(\.status), [.proposed, .confirmed])
    }

    func testFormerlyRemovedFlag() {
        var person = Person(displayName: "Анна")
        person.former = [FormerValue(field: "emails", value: "old@example.test", reason: .removedByUser)]
        person.observations = [observation("emails", "old@example.test"), observation("emails", "new@example.test")]
        let items = OSINTCardGrouping.items(for: person)
        XCTAssertEqual(items.map(\.formerlyRemoved), [true, false])
    }

    func testLeakAndDomainFieldsHaveGroupsAndTitles() {
        XCTAssertEqual(OSINTCardGrouping.group(for: "leak.name"), .breaches)
        XCTAssertEqual(OSINTCardGrouping.group(for: "leak.device"), .breaches)
        XCTAssertEqual(OSINTCardGrouping.group(for: "domain.ip"), .domains)
        XCTAssertEqual(OSINTCardGrouping.group(for: "domain.whois"), .domains)
        XCTAssertEqual(OSINTCardGrouping.group(for: "organization.asn"), .organizations)
        XCTAssertEqual(OSINTCardGrouping.title(for: "leak.ip"), "IP в утечке")
        XCTAssertEqual(OSINTCardGrouping.title(for: "domain.whois"), "WHOIS")
        XCTAssertEqual(OSINTCardGrouping.title(for: "organization.asn"), "автономная система")
    }
}
