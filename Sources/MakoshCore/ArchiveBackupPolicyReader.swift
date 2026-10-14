import Foundation

/// Local archive policy access; no communication account or contact-store reads.
public actor ArchiveBackupPolicyReader {
    private let connectionString: String, schema: String
    private let keys: ArchiveBackupKeys
    private var store: MessageArchiveStore?
    private var sawArchive = false
    public init(connectionString: String, schema: String, keys: ArchiveBackupKeys = .keychain) {
        self.connectionString = connectionString; self.schema = schema; self.keys = keys
    }
    public func policy(_ identity: MessageArchiveIdentity) throws -> Bool? {
        try Task.checkCancellation()
        do { return try open()?.explicitConversationFileSavingEnabled(identity: identity) }
        catch { store = nil; throw error }
    }
    public func disabledPolicies() throws -> [MessageArchiveIdentity] {
        try Task.checkCancellation()
        do { return try open()?.disabledConversationFilePolicies() ?? [] }
        catch { store = nil; throw error }
    }
    private func open() throws -> MessageArchiveStore? {
        if let store { return store }
        guard try ArchiveBackupDestination.archiveExists(connectionString: connectionString, schema: schema) else {
            if sawArchive { throw MessageArchiveError.integrity }
            return nil
        }
        sawArchive = true
        let keys = keys
        let result = try MessageArchiveStore(connectionString: connectionString, schema: schema, readOnly: true) { id, creation in
            guard !creation, let key = try keys.lookup(id), key.count == 32 else { throw MessageArchiveError.keyUnavailable }
            return key
        }
        store = result; return result
    }
}
