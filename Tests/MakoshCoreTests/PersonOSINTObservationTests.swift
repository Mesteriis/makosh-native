import Foundation
import XCTest

@testable import MakoshCore

/// Proposed OSINT observations: added without touching values, accepted by hand without merging, rejected for good.
final class PersonOSINTObservationTests: XCTestCase {
    private var database: PostgresTestDatabase!
    private var store: PersonStore!
    private let server = UUID()
    private var identity: ServiceIdentity { ServiceIdentity(service: "osint", accountID: server.uuidString, externalID: "sk-1") }
    private let mail = ImportSource(service: "mail", accountID: "m")

    override func setUpWithError() throws {
        database = try PostgresTestDatabase()
        store = try database.makeStore()
    }
    override func tearDownWithError() throws {
        store = nil
        try database?.cleanup()
    }

    private func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }

    private func proposed(_ field: String, _ value: String, at: Double = 100) -> Observation {
        Observation(field: field, value: value, source: SourceStamp(identity: identity, fetchedAt: date(at)), status: .proposed)
    }

    private func anna() throws -> UUID {
        try store.createPerson(draft: .init(displayName: "Анна", phones: ["+79990000000"], emails: ["anna@example.test"]))
    }

    func testAddProposedSkipsCurrentAndKnownPairs() throws {
        let id = try anna()
        let first = try store.addProposedObservations(
            personID: id, [proposed("emails", "anna@example.test"), proposed("usernames", "anna_k")])
        XCTAssertEqual(first, 1, "the current address is not proposed again")
        var person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.usernames, [], "a proposal does not become a value")
        XCTAssertEqual(person.observations.filter { $0.status == .proposed }.map(\.value), ["anna_k"])
        XCTAssertTrue(person.identities.contains(identity), "the sketch identity appears with the first proposal")
        let revision = person.revision
        let again = try store.addProposedObservations(
            personID: id, [proposed("usernames", "anna_k"), proposed("social.github", "https://github.com/anna_k")])
        XCTAssertEqual(again, 1, "an already proposed pair is skipped")
        person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.revision, revision + 1)
        let none = try store.addProposedObservations(personID: id, [])
        XCTAssertEqual(none, 0)
    }

    func testAttachIdentityIsIdempotent() throws {
        let id = try anna()
        let before = try XCTUnwrap(try store.person(id: id)).revision
        try store.attachIdentity(personID: id, identity)
        try store.attachIdentity(personID: id, identity)
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.identities.filter { $0 == identity }.count, 1)
        XCTAssertEqual(person.revision, before + 1, "the second attach changes nothing")
    }

    func testAcceptEmailBecomesManualAndConfirmed() throws {
        let id = try anna()
        _ = try store.addProposedObservations(personID: id, [proposed("emails", "anna.k@example.test")])
        let observation = try XCTUnwrap(try store.person(id: id)?.observations.first { $0.status == .proposed })
        let outcome = try store.acceptObservation(personID: id, observationID: observation.id)
        XCTAssertEqual(outcome, .applied)
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.emails, ["anna@example.test", "anna.k@example.test"])
        XCTAssertTrue(
            person.manualValues.contains(ManualValue(field: "emails", value: "anna.k@example.test")), "an accepted value is the user's")
        XCTAssertEqual(person.observations.first { $0.id == observation.id }?.status, .confirmed)
        XCTAssertThrowsError(try store.acceptObservation(personID: id, observationID: observation.id), "only a proposal can be accepted")
    }

    func testAcceptDuplicateEmailDoesNotMerge() throws {
        let id = try anna()
        let other = try store.createPerson(draft: .init(displayName: "Другая Анна", emails: ["Anna.K@Example.test"]))
        _ = try store.addProposedObservations(personID: id, [proposed("emails", "anna.k@example.test")])
        let observation = try XCTUnwrap(try store.person(id: id)?.observations.first { $0.status == .proposed })
        let outcome = try store.acceptObservation(personID: id, observationID: observation.id)
        XCTAssertEqual(outcome, .duplicateOf(other))
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.emails, ["anna@example.test"], "nothing applied")
        XCTAssertEqual(person.observations.first { $0.id == observation.id }?.status, .proposed, "still a proposal")
        XCTAssertEqual(try store.persons().count, 2, "no merge happened")
        XCTAssertNotNil(try store.person(id: other))
    }

    func testAcceptSocialStaysObservationConfirmed() throws {
        let id = try anna()
        _ = try store.addProposedObservations(
            personID: id, [proposed("social.github", "https://github.com/anna_k"), proposed("breach", "Adobe, 2013-10-04")])
        let person = try XCTUnwrap(try store.person(id: id))
        for observation in person.observations where observation.status == .proposed {
            XCTAssertEqual(try store.acceptObservation(personID: id, observationID: observation.id), .applied)
        }
        let after = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(after.observations.filter { $0.status == .confirmed }.count, 2)
        XCTAssertEqual(after.tags, [])
        XCTAssertEqual(after.emails, ["anna@example.test"])
        XCTAssertEqual(after.organization, "")
    }

    func testRejectedIsNotReproposed() throws {
        let id = try anna()
        _ = try store.addProposedObservations(personID: id, [proposed("usernames", "anna_k")])
        let observation = try XCTUnwrap(try store.person(id: id)?.observations.first { $0.status == .proposed })
        try store.setObservationStatus(personID: id, observationID: observation.id, status: .rejected)
        let person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.observations.first { $0.id == observation.id }?.status, .rejected)
        XCTAssertFalse(person.observations.first { $0.id == observation.id }!.isApplied)
        XCTAssertEqual(try store.addProposedObservations(personID: id, [proposed("usernames", "anna_k", at: 200)]), 0)
        XCTAssertThrowsError(
            try store.setObservationStatus(personID: id, observationID: observation.id, status: .confirmed), "rejected stays rejected")
    }

    func testReconciliationIgnoresRejected() throws {
        let id = try store.linkImportedPerson(
            .init(externalID: "a@x", displayName: "A"), source: mail, fetchedAt: date(100), contactID: nil)
        _ = try store.addProposedObservations(personID: id, [proposed("displayName", "Анна Каренина", at: 900)])
        let observation = try XCTUnwrap(try store.person(id: id)?.observations.first { $0.status == .proposed })
        try store.setObservationStatus(personID: id, observationID: observation.id, status: .rejected)
        XCTAssertEqual(try store.person(id: id)?.displayName, "A")
        _ = try store.linkImportedPerson(.init(externalID: "a@x", displayName: "Анна"), source: mail, fetchedAt: date(500), contactID: nil)
        XCTAssertEqual(try store.person(id: id)?.displayName, "Анна", "a rejected proposal with a later date does not block the source")
    }

    func testRemoveObservationsKeepsConfirmed() throws {
        let id = try anna()
        _ = try store.addProposedObservations(
            personID: id,
            [proposed("usernames", "anna_k"), proposed("social.github", "https://github.com/anna_k"), proposed("breach", "Adobe")])
        var person = try XCTUnwrap(try store.person(id: id))
        let social = try XCTUnwrap(person.observations.first { $0.field == "social.github" })
        let breach = try XCTUnwrap(person.observations.first { $0.field == "breach" })
        _ = try store.acceptObservation(personID: id, observationID: social.id)
        try store.setObservationStatus(personID: id, observationID: breach.id, status: .rejected)
        let removed = try store.removeObservations(personID: id, service: "osint")
        XCTAssertEqual(removed, 2, "the proposed username and the rejected breach")
        person = try XCTUnwrap(try store.person(id: id))
        XCTAssertEqual(person.observations.filter { $0.source.identity.service == "osint" }.map(\.field), ["social.github"])
        XCTAssertTrue(person.identities.contains(identity), "a confirmed observation keeps its provenance identity")
        XCTAssertEqual(try store.removeObservations(personID: id, service: "osint"), 0)
        // A person with proposals only loses the sketch identity together with them.
        let other = try store.createPerson(draft: .init(displayName: "Борис"))
        _ = try store.addProposedObservations(personID: other, [proposed("usernames", "boris")])
        XCTAssertEqual(try store.removeObservations(personID: other, service: "osint"), 1)
        XCTAssertFalse(try XCTUnwrap(try store.person(id: other)).identities.contains(identity))
    }

    func testDetachOSINTIdentityIsRefused() throws {
        let id = try store.linkImportedPerson(
            .init(externalID: "a@x", displayName: "A", emails: ["a@x"]), source: mail, fetchedAt: date(100), contactID: nil)
        _ = try store.addProposedObservations(personID: id, [proposed("usernames", "anna_k")])
        XCTAssertThrowsError(try store.detachIdentity(personID: id, identity: identity))
        XCTAssertEqual(try store.persons().count, 1)
    }

    func testOldRowsDecodeWithoutStatus() throws {
        let json = """
            {"id":"\(UUID().uuidString)","field":"emails","value":"a@x","source":{"identity":{"service":"mail","accountID":"m","externalID":"a@x"},"fetchedAt":100}}
            """
        let observation = try JSONDecoder().decode(Observation.self, from: Data(json.utf8))
        XCTAssertEqual(observation.status, .observed)
        XCTAssertTrue(observation.isApplied)
        let rejected = try JSONDecoder().decode(ObservationStatus.self, from: Data("\"rejected\"".utf8))
        XCTAssertEqual(rejected, .rejected)
    }
}
