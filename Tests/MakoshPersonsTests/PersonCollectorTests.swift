import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class PersonCollectorTests: XCTestCase {
    private var db: PersonsTestDatabase!
    private var persons: PersonStore!
    private var store: PersonsStore!
    private var collector: PersonCollector!
    private let mail = ImportSource(service: "mail", accountID: "m")
    private let telegram = ImportSource(service: "telegram", accountID: "t")
    private let google = ImportSource(service: "google-contacts", accountID: "subject")
    private let when = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        db = try personsDatabase()
        persons = try db.persons()
        store = try await personsStore(db)
        collector = PersonCollector(persons: persons, store: store)
    }

    private func mailObservation(_ address: String, name: String? = nil) -> PersonSourceObservation {
        PersonSourceObservation(
            source: mail, person: ImportedPerson(externalID: address, displayName: name ?? address, emails: [address]), observedAt: when,
            evidence: .mail(MailEvidence(accountID: "m", address: address, spam: false)))
    }

    private func telegramObservation(_ peer: String, name: String, phone: String) -> PersonSourceObservation {
        PersonSourceObservation(
            source: telegram, person: ImportedPerson(externalID: peer, displayName: name, phones: [phone]), observedAt: when,
            evidence: .conversation)
    }

    func testConversationObservationCreatesPersonOnce() async throws {
        let first = try await collector.collect([telegramObservation("42", name: "Анна", phone: "+7 916 000-00-00")])
        XCTAssertEqual(first.created, 1)
        let second = try await collector.collect([telegramObservation("42", name: "Анна", phone: "+7 916 000-00-00")])
        XCTAssertEqual(second.created, 0)
        XCTAssertLessThanOrEqual(second.updated, 1)
        XCTAssertEqual(try persons.persons().count, 1)
        XCTAssertEqual(try persons.persons().first?.displayName, "Анна")
    }

    func testPhoneMatchAutoMergesTelegramIntoMailPerson() async throws {
        let mailPerson = try persons.createPerson(
            draft: .init(displayName: "Иванов", phones: ["+7 916 000-00-00"], emails: ["i@sidorov.ru"]))
        let result = try await collector.collect([telegramObservation("42", name: "Иванов TG", phone: "8 916 000 00 00")])
        XCTAssertEqual(result.merged.count, 1)
        XCTAssertEqual(result.merged.first?.survivor, mailPerson)
        XCTAssertEqual(try persons.persons().count, 1)
        let merged = try XCTUnwrap(try persons.person(id: mailPerson))
        XCTAssertEqual(merged.identities.map(\.externalID), ["42"])
        XCTAssertEqual(merged.displayName, "Иванов")
    }

    func testDomainOrganizationAppearsAtSecondAddress() async throws {
        let one = try await collector.collect([mailObservation("a@sidorov.ru", name: "A")])
        XCTAssertEqual(one.suggestedMemberships, 0)
        XCTAssertTrue(try persons.organizations().isEmpty)
        let two = try await collector.collect([mailObservation("b@sidorov.ru", name: "B")])
        XCTAssertEqual(two.suggestedMemberships, 2)
        let organizations = try persons.organizations()
        XCTAssertEqual(organizations.map(\.displayName), ["sidorov.ru"])
        let members = try persons.members(of: organizations[0].id)
        XCTAssertEqual(members.count, 2)
        XCTAssertTrue(members.allSatisfy { $0.state == .suggested && $0.origin == .emailDomain("sidorov.ru") })
        let again = try await collector.collect([mailObservation("a@sidorov.ru", name: "A")])
        XCTAssertEqual(again.suggestedMemberships, 0, "an existing pair is not suggested twice")
        XCTAssertEqual(try persons.organizations().count, 1)
    }

    func testCompanyFieldCreatesOrganizationOnce() async throws {
        let observation = PersonSourceObservation(
            source: google,
            person: ImportedPerson(
                externalID: "c1", displayName: "Пётр", organization: "ИП Сидоров", jobTitle: "Менеджер", emails: ["p@gmail.com"]),
            observedAt: when, evidence: .book)
        let result = try await collector.collect([observation])
        XCTAssertEqual(result.suggestedMemberships, 1)
        let organization = try XCTUnwrap(try persons.organization(named: "ИП Сидоров"))
        XCTAssertEqual(try persons.members(of: organization.id).first?.role, "Менеджер")
        _ = try await collector.collect([observation])
        XCTAssertEqual(try persons.organizations().count, 1)
    }

    func testSpamOnlyPersonIsHiddenAndReturns() async throws {
        _ = try await collector.collect([mailObservation("s@x.ru")])
        let id = try XCTUnwrap(try persons.persons().first?.id)
        // The one letter that created the person was moved to Spam: spam now outweighs clean.
        var result = try await collector.collect([], spam: [MailEvidence(accountID: "m", address: "s@x.ru", spam: true)])
        XCTAssertEqual(result.hidden, [id])
        XCTAssertTrue(try XCTUnwrap(try persons.person(id: id)).hiddenAsSpam)
        _ = try await collector.collect([], spam: [MailEvidence(accountID: "m", address: "s@x.ru", spam: true)])
        let evidence = try persons.mailEvidence(address: "s@x.ru")
        XCTAssertEqual(evidence.spam, 2)
        XCTAssertEqual(evidence.clean, 1)
        result = try await collector.collect([mailObservation("s@x.ru")])
        XCTAssertEqual(result.restored, [id])
        XCTAssertFalse(try XCTUnwrap(try persons.person(id: id)).hiddenAsSpam)
    }

    func testFreshSpamSenderNeverBecomesAPerson() async throws {
        let result = try await collector.collect([], spam: [MailEvidence(accountID: "m", address: "spam@evil.test", spam: true)])
        XCTAssertTrue(result.hidden.isEmpty)
        XCTAssertTrue(try persons.allPersons(includingInactive: true).isEmpty)
        XCTAssertEqual(try persons.mailEvidence(address: "spam@evil.test").spam, 1)
    }

    func testHiddenPersonDoesNotCountForDomainRule() async throws {
        _ = try await collector.collect([mailObservation("a@sidorov.ru")])
        let a = try XCTUnwrap(try persons.persons().first?.id)
        try persons.setHiddenAsSpam(id: a, true)
        let result = try await collector.collect([mailObservation("b@sidorov.ru")])
        XCTAssertEqual(result.suggestedMemberships, 0)
        XCTAssertTrue(try persons.organizations().isEmpty)
    }

    func testBookSourceSetsFlagWithOrigin() async throws {
        let observation = PersonSourceObservation(
            source: google, person: ImportedPerson(externalID: "c1", displayName: "Пётр", emails: ["p@gmail.com"]), observedAt: when,
            evidence: .book)
        _ = try await collector.collect([observation], addressBookSource: google)
        let person = try XCTUnwrap(try persons.persons().first)
        XCTAssertTrue(person.addressBook)
        XCTAssertEqual(person.addressBookOrigin, .sourceAccount(google))
        _ = try await collector.collect([observation])
        XCTAssertTrue(try XCTUnwrap(try persons.person(id: person.id)).addressBook, "a later read without the source flag keeps it")
    }
}
