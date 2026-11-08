import Foundation
import XCTest

@testable import MakoshCore

final class PersonMatchingTests: XCTestCase {
    private var database: PostgresTestDatabase!
    private var store: PersonStore!
    private let telegram = ImportSource(service: "telegram", accountID: "t")
    override func setUpWithError() throws {
        database = try PostgresTestDatabase()
        store = try database.makeStore()
    }
    override func tearDownWithError() throws {
        store = nil
        try database?.cleanup()
    }
    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    private func valueRows() throws -> [[String]] {
        try database.execute("SELECT person_id::text, field, normalized FROM person_values ORDER BY 1, 2, 3")
    }

    func testPhoneNormalization() {
        XCTAssertEqual(PersonMatching.normalizedPhone("8 (916) 000-00-00"), "79160000000")
        XCTAssertEqual(PersonMatching.normalizedPhone("+7 916 000-00-00"), "79160000000")
        XCTAssertEqual(PersonMatching.normalizedPhone("+49 30 1234567"), "49301234567")
        XCTAssertEqual(PersonMatching.normalizedPhone("12345"), "")
    }

    func testEmailNormalizationAndRoleAddresses() {
        XCTAssertEqual(PersonMatching.normalizedEmail("  Ivan@Sidorov.RU "), "ivan@sidorov.ru")
        XCTAssertEqual(PersonMatching.normalizedEmail("not an address"), "")
        XCTAssertTrue(PersonMatching.isRoleAddress("Info@firm.ru"))
        XCTAssertTrue(PersonMatching.isRoleAddress("no-reply@shop.ru"))
        XCTAssertFalse(PersonMatching.isRoleAddress("ivan@firm.ru"))
    }

    func testRoleAddressDoesNotAutoMergeButIsADuplicateCandidate() throws {
        let a = try store.createPerson(draft: .init(displayName: "A", emails: ["info@firm.ru"]))
        let b = try store.createPerson(draft: .init(displayName: "B", emails: ["Info@firm.ru"]))
        XCTAssertNil(try store.autoMergeCandidate(for: a))
        let duplicates = try store.duplicateCandidates()
        XCTAssertEqual(duplicates.count, 1)
        XCTAssertEqual(Set([duplicates[0].firstID, duplicates[0].secondID]), [a, b])
        XCTAssertEqual(duplicates[0].reasons, ["Совпадает email"])
    }

    func testSharedValueOfThreePersonsDoesNotAutoMerge() throws {
        var ids: [UUID] = []
        for name in ["A", "B", "C"] { ids.append(try store.createPerson(draft: .init(displayName: name, phones: ["+7 916 000-00-00"]))) }
        for id in ids { XCTAssertNil(try store.autoMergeCandidate(for: id)) }
        XCTAssertEqual(try store.duplicateCandidates().count, 3)
    }

    func testExactMatchAutoMergesIntoTheOlder() throws {
        let older = try store.createPerson(draft: .init(displayName: "A", phones: ["+7 916 000-00-00"]))
        let newer = try store.linkImportedPerson(
            .init(externalID: "tg", displayName: "A tg", phones: ["8 916 000 00 00"]), source: telegram, fetchedAt: date(100),
            contactID: nil)
        XCTAssertEqual(try store.autoMergeCandidate(for: newer), older)
        XCTAssertEqual(try store.autoMerge(personID: newer)?.survivor, older)
        XCTAssertEqual(try store.domainAddressCounts(domains: ["x.ru"]), ["x.ru": 0])
        XCTAssertNil(try store.person(id: newer))
        let merged = try XCTUnwrap(try store.person(id: older))
        XCTAssertEqual(merged.identities.count, 1)
        XCTAssertEqual(merged.events.last?.kind, "autoMerged")
        XCTAssertTrue(merged.events.last?.detail.contains("телефон") ?? false)
        XCTAssertEqual(try valueRows().filter { $0[1] == "phones" }.count, 1)
        XCTAssertNil(try store.autoMerge(personID: older))
    }

    func testNoMergePairBlocksAutoMerge() throws {
        let mail = ImportSource(service: "mail", accountID: "m")
        let id = try store.linkImportedPerson(
            .init(externalID: "a@x", displayName: "A", phones: ["+7 916 000-00-00"], emails: ["a@x"]), source: mail, fetchedAt: date(100),
            contactID: nil)
        let telegramIdentity = ServiceIdentity(service: "telegram", accountID: "t", externalID: "42")
        _ = try store.linkImportedPerson(
            .init(externalID: "42", displayName: "A tg", phones: ["+7 916 000-00-00"]), source: telegram, fetchedAt: date(100),
            contactID: id)
        let detached = try store.detachIdentity(personID: id, identity: telegramIdentity)
        XCTAssertEqual(try store.person(id: detached)?.phones, ["+7 916 000-00-00"])
        XCTAssertEqual(try store.person(id: id)?.phones, ["+7 916 000-00-00"])
        XCTAssertNil(try store.autoMergeCandidate(for: detached))
        XCTAssertNil(try store.autoMergeCandidate(for: id))
        XCTAssertTrue(try store.duplicateCandidates().isEmpty)
    }

    func testKindMismatchNeverAutoMerges() throws {
        let person = try store.createPerson(draft: .init(displayName: "A", emails: ["a@firm.ru"]))
        let organization = try store.createOrganization(name: "Firm")
        var draft = try XCTUnwrap(try store.person(id: organization)).draft
        draft.emails = ["a@firm.ru"]
        try store.updatePerson(id: organization, draft: draft)
        XCTAssertNil(try store.autoMergeCandidate(for: person))
        XCTAssertNil(try store.autoMergeCandidate(for: organization))
        XCTAssertTrue(try store.duplicateCandidates().isEmpty)
    }

    func testValuesIndexFollowsWrites() throws {
        let id = try store.createPerson(draft: .init(displayName: "A", phones: ["+7 916 000-00-00"], emails: ["A@x"]))
        XCTAssertEqual(
            try valueRows(), [[id.uuidString.lowercased(), "emails", "a@x"], [id.uuidString.lowercased(), "phones", "79160000000"]])
        try store.removeValue(personID: id, field: .phones, value: "+7 916 000-00-00", reason: .removedByUser)
        XCTAssertEqual(try valueRows().map { $0[1] }, ["emails"])
        var draft = try XCTUnwrap(try store.person(id: id)).draft
        draft.emails = []
        draft.phones = ["12345"]
        try store.updatePerson(id: id, draft: draft)
        XCTAssertTrue(try valueRows().isEmpty, "Short phones and cleared emails leave no index rows")
    }
}
