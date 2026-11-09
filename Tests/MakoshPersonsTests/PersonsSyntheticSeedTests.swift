import Foundation
import MakoshCore
import MakoshGoogle
import XCTest

@testable import MakoshPersons

final class PersonsSyntheticSeedTests: XCTestCase {
    func testSeedIsIdempotentAndMatchesExpectations() async throws {
        let db = try personsDatabase()
        let persons = try db.persons()
        let store = try await personsStore(db)
        let books = PersonsSyntheticSeed.books()
        let service = PersonsService(
            persons: persons, store: store, vault: PersonsCredentialVault(access: .memory()),
            adapterFactory: { book, _ in
                guard let adapter = books[book.accountID] else { throw PersonsFailure.notFound }
                return adapter
            }, google: nil, grants: GoogleGrantVault(access: .memory()))
        try await service.open()
        try await PersonsSyntheticSeed.seed(service: service, persons: persons, books: books)
        await service.settled()

        let organizations = try persons.organizations()
        XCTAssertEqual(organizations.map(\.displayName), ["sidorov.ru"], "three inbound letters from one domain make one organization")
        let memberships = try persons.allMemberships(includingRemoved: false).filter { $0.organizationID == organizations.first?.id }
        XCTAssertEqual(memberships.count, 3)
        XCTAssertTrue(memberships.allSatisfy { $0.state == .suggested })

        let everyone = try persons.allPersons(includingInactive: true)
        XCTAssertFalse(everyone.contains { $0.emails.contains("spam@evil.test") }, "a junk letter never creates a person")
        XCTAssertEqual(everyone.filter(\.hiddenAsSpam).count, 0)
        XCTAssertEqual(try persons.mailEvidence(address: "spam@evil.test").spam, 1)
        XCTAssertEqual(everyone.filter { $0.deletedAt != nil }.count, 1, "one person waits in «Удалённые»")

        let anna = try XCTUnwrap(everyone.first { $0.emails.contains("anna@sidorov.ru") })
        XCTAssertTrue(anna.identities.contains { $0.service == "telegram" }, "the Telegram contact merged into Anna by phone")
        XCTAssertTrue(anna.addressBook)
        XCTAssertEqual(everyone.filter { $0.isActive && $0.kind == .person }.count, 3, "Anna, Boris, Viktor")

        let duplicates = try persons.duplicateCandidates()
        XCTAssertEqual(duplicates.count, 1, "Anna and Boris share the role address info@sidorov.ru and are only a duplicate hint")

        let snapshot = try await service.snapshot()
        XCTAssertEqual(snapshot.openAttempts.filter { $0.state == .unknown }.count, 1, "the first Google write dropped its connection")
        let blocked = snapshot.blocked.values.flatMap(\.values)
        XCTAssertEqual(blocked, [.noPhoneOrPeer], "Viktor is flagged without a phone, so Telegram cannot take him")
        XCTAssertEqual(snapshot.books.filter { $0.kind == .synthetic }.count, 4)

        try await PersonsSyntheticSeed.seed(service: service, persons: persons, books: books)
        await service.settled()
        XCTAssertEqual(try persons.allPersons(includingInactive: true).count, everyone.count, "a second seed changes nothing")
        let again = try await service.snapshot()
        XCTAssertEqual(again.books.count, snapshot.books.count)
        XCTAssertEqual(try persons.mailEvidence(address: "spam@evil.test").spam, 1)
    }
}
