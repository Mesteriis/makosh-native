import Foundation
import MakoshCore

public struct TelemostDossierReference: Codable, Equatable, Sendable {
    public let meetingID: UUID
    public let note: ContactNote
}
public struct TelemostDossierJob: Codable, Equatable, Sendable {
    public let id: UUID
    public let contactID: UUID
    public let reference: TelemostDossierReference
    public var acknowledged: Bool
}
extension TelemostRepository {
    public func prepareDossierReference(meetingID: UUID, contactID: UUID) throws -> TelemostDossierJob {
        let db = try db()
        return try db.transaction {
            let meeting = try meeting(id: meetingID), owner = try owner(meeting.accountID)
            let binding = telemostIdentityKey([meetingID.uuidString, contactID.uuidString])
            if let existing: UUID = try record(UUID.self, kind: "dossier-binding", key: binding) {
                guard let job: TelemostDossierJob = try record(TelemostDossierJob.self, kind: "dossier", key: existing.uuidString),
                      job.contactID == contactID, job.reference.meetingID == meetingID else { throw TelemostFailure.storage }
                return job
            }
            guard let localArea = db.localArea else { throw TelemostFailure.storage }
            let id = UUID(), source = SourceStamp(identity: .init(service: "telemost",
                accountID: meeting.accountID?.uuidString ?? "local:" + localArea.uuidString,
                externalID: meeting.validatedURL.conferenceID), fetchedAt: meeting.conference?.observedAt ?? meeting.updatedAt)
            let title = meeting.localTitle.isEmpty ? "Встреча Телемост" : meeting.localTitle
            let note = ContactNote(id: id, text: title + "\n" + meeting.validatedURL.url.absoluteString + "\nСвязь добавлена вручную в Макоше.", source: source)
            let job = TelemostDossierJob(id: id, contactID: contactID, reference: .init(meetingID: meetingID, note: note), acknowledged: false)
            try put(job, kind: "dossier", key: id.uuidString, owner: owner, status: "pending")
            try put(id, kind: "dossier-binding", key: binding, owner: owner, versioned: false)
            return job
        }
    }
    public func pendingDossierReferences() throws -> [TelemostDossierJob] {
        try records(TelemostDossierJob.self, kind: "dossier", status: "pending")
    }
    public func acknowledgeDossierReference(id: UUID) throws {
        let db = try db()
        try db.transaction {
            guard var job: TelemostDossierJob = try record(TelemostDossierJob.self, kind: "dossier", key: id.uuidString) else { throw TelemostFailure.missing }
            if job.acknowledged { return }
            let meeting = try meeting(id: job.reference.meetingID); job.acknowledged = true
            try put(job, kind: "dossier", key: id.uuidString, owner: owner(meeting.accountID), status: "acknowledged")
        }
    }
}
extension TelemostWorker {
    public func linkDossier(meetingID: UUID, contactID: UUID) async throws -> UUID {
        try admitWork(); defer { finishWork() }
        guard let contacts else { throw TelemostFailure.invalidConfiguration }
        let meeting = try await repository.meeting(id: meetingID)
        let generation = meeting.accountID.map { self.generation($0) }
        try Task.checkCancellation()
        let job = try await repository.prepareDossierReference(meetingID: meetingID, contactID: contactID)
        try Task.checkCancellation()
        guard !closing else { throw CancellationError() }
        if let accountID = meeting.accountID, let generation { try requireCurrent(accountID, generation) }
        // Always run the idempotent command: a previously acknowledged note may have moved in a merge.
        let result = try await contacts.apply(.addSourceNote(contactID: job.contactID, note: job.reference.note))
        guard case .sourceNoted(let ownerID) = result.value else { throw TelemostFailure.conflict }
        try await repository.acknowledgeDossierReference(id: job.id)
        return ownerID
    }
}
