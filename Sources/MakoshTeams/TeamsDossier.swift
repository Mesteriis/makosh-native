import Foundation
import MakoshCore

extension TeamsPerson {
    public var dossierContact: ImportedContact? {
        guard UUID(uuidString: tenantID) != nil, UUID(uuidString: userID) != nil,
              !displayName.isEmpty, displayName.utf8.count <= 1024 else { return nil }
        // The guest's observed tenant is retained; never substitute the owning account tenant.
        return ImportedContact(externalID: teamsIdentityKey([tenantID, userID]).teamsBase64URL,
            displayName: displayName, emails: email.map { [$0] } ?? [], tags: ["Microsoft Teams"])
    }
}
