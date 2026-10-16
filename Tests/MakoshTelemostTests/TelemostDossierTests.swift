import XCTest
@testable import MakoshCore
@testable import MakoshTelemost

@MainActor
final class TelemostDossierTests: XCTestCase {
    func fixture() async throws -> (TelemostTestDatabase, TelemostRepository, ContactWorkspaceWorker, UUID, UUID) {
        let db = try TelemostTestDatabase(); addTeardownBlock { try db.cleanup() }
        let core = ContactWorkspaceWorker(configuration: db.configuration); _ = try await core.open()
        let result = try await core.apply(.save(draft: .init(displayName: "Synthetic dossier"), id: nil))
        guard case .saved(let contactID) = result.value else { throw TelemostFailure.storage }
        let repo = TelemostRepository(keyProvider: telemostTestKey); try await repo.open(configuration: db.configuration)
        addTeardownBlock { await repo.close() }
        let local = TelemostLocalMeeting(accountID: nil, validatedURL: try .init("https://telemost.yandex.ru/j/123"), localTitle: "Synthetic meeting")
        try await repo.saveLocal(local)
        return (db, repo, core, contactID, local.id)
    }
    func testLostProjectionAcknowledgementDoesNotDuplicate() async throws {
        let (db, repo, core, contactID, meetingID) = try await fixture()
        let worker = TelemostWorker(repository: repo, contacts: core)
        let schema = "\"\(db.configuration.schema)\"."
        try db.execute("CREATE FUNCTION \(schema)reject_dossier_ack() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF OLD.kind='dossier' THEN RAISE EXCEPTION 'synthetic ack loss'; END IF; RETURN NEW; END $$")
        try db.execute("CREATE TRIGGER reject_dossier_ack BEFORE UPDATE ON \(schema)telemost_records FOR EACH ROW EXECUTE FUNCTION \(schema)reject_dossier_ack()")
        do { _ = try await worker.linkDossier(meetingID: meetingID, contactID: contactID); XCTFail("ack failure hidden") } catch {}
        let committed = try await core.snapshot(); XCTAssertEqual(committed.contacts.first?.notes.count, 1)
        let pending = try await repo.pendingDossierReferences(); XCTAssertEqual(pending.count, 1)
        try db.execute("DROP TRIGGER reject_dossier_ack ON \(schema)telemost_records")
        let owner = try await worker.linkDossier(meetingID: meetingID, contactID: contactID)
        let retried = try await core.snapshot(), finished = try await repo.pendingDossierReferences()
        XCTAssertEqual(owner, contactID); XCTAssertEqual(retried.contacts.first?.notes.count, 1); XCTAssertTrue(finished.isEmpty)
    }
    func testProjectionRetryAfterMergeReturnsOwner() async throws {
        let (_, repo, core, contactID, meetingID) = try await fixture()
        let worker = TelemostWorker(repository: repo, contacts: core)
        _ = try await worker.linkDossier(meetingID: meetingID, contactID: contactID)
        let other = try await core.apply(.save(draft: .init(displayName: "Survivor"), id: nil))
        guard case .saved(let survivor) = other.value else { throw TelemostFailure.storage }
        _ = try await core.apply(.merge(survivorID: survivor, removedID: contactID))
        let owner = try await worker.linkDossier(meetingID: meetingID, contactID: contactID)
        XCTAssertEqual(owner, survivor)
        let snapshot = try await core.snapshot(); XCTAssertEqual(snapshot.contacts.first?.notes.count, 1)
    }
    func testMeetingReferenceNeverCreatesPersonIdentity() async throws {
        let (_, repo, core, contactID, meetingID) = try await fixture()
        let worker = TelemostWorker(repository: repo, contacts: core)
        _ = try await worker.linkDossier(meetingID: meetingID, contactID: contactID)
        let snapshot = try await core.snapshot(), contact = try XCTUnwrap(snapshot.contacts.first)
        XCTAssertTrue(contact.identities.isEmpty)
        XCTAssertEqual(contact.notes.first?.source.identity.service, "telemost")
        XCTAssertTrue(contact.notes.first?.text.contains("https://telemost.yandex.ru/j/123") == true)
    }
    func testCancelledSourceNoteDoesNotBlockOtherWrites() async throws {
        let (_, _, core, contactID, _) = try await fixture()
        let note = ContactNote(text: "Cancelled source reference", source: .init(identity: .init(service: "telemost", accountID: "qa", externalID: "123")))
        let task = Task { try await core.apply(.addSourceNote(contactID: contactID, note: note)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled source write") } catch {}
        _ = try await core.apply(.addNote(contactID: contactID, text: "Allowed later manual note"))
        let snapshot = try await core.snapshot()
        XCTAssertEqual(snapshot.contacts.first?.notes.map(\.text), ["Allowed later manual note"])
    }
}
