import Foundation
import MakoshCore

extension TeamsPerson {
    public var dossierContact: ImportedContact? {
        guard UUID(uuidString: tenantID) != nil, UUID(uuidString: userID) != nil,
            !displayName.isEmpty, displayName.utf8.count <= 1024
        else { return nil }
        // The guest's observed tenant is retained; never substitute the owning account tenant.
        return ImportedContact(
            externalID: dossierExternalID,
            displayName: displayName, emails: email.map { [$0] } ?? [], tags: ["Microsoft Teams"])
    }
}

extension TeamsPerson {
    var dossierExternalID: String { teamsIdentityKey([tenantID, userID]).teamsBase64URL }

    /// The dossier external ID of a retained archive payload's author, so AI
    /// contact access applies to Teams messages. Nil without a verifiable person.
    public static func archiveAuthorKey(_ sourcePayload: Data) -> String? {
        struct Payload: Decodable { let author: TeamsPerson? }
        guard let author = (try? JSONDecoder().decode(Payload.self, from: sourcePayload))?.author,
            UUID(uuidString: author.tenantID) != nil, UUID(uuidString: author.userID) != nil
        else { return nil }
        return author.dossierExternalID
    }
}
