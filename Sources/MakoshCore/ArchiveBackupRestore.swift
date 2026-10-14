import Foundation
import CPostgres

struct ArchiveBackupBootstrap {
    let verified: ArchiveBackupVerified
    let destinationStorageID: String?
    let disabledPolicies: [MessageArchiveIdentity]
    let installKey: @Sendable (UUID, Data) throws -> Void
}

enum ArchiveBackupDestination {
    static func requireNewSchema(connectionString: String, schema: String) throws {
        guard try !exists(connectionString: connectionString, schema: schema, archiveOnly: false) else { throw ArchiveBackupError.conflict }
    }
    static func archiveExists(connectionString: String, schema: String) throws -> Bool {
        try exists(connectionString: connectionString, schema: schema, archiveOnly: true)
    }
    private static func exists(connectionString: String, schema: String, archiveOnly: Bool) throws -> Bool {
        let bytes = Array(schema.utf8)
        guard !bytes.isEmpty, bytes.count <= 63, (97...122).contains(bytes[0]),
              bytes.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
              !connectionString.isEmpty, connectionString.utf8.count <= 65_536, !connectionString.utf8.contains(0) else { throw ArchiveBackupError.invalid }
        let db = connectionString.withCString { dsn in
            "dbname".withCString { key in "connect_timeout".withCString { timeout in "5".withCString { value in
                let keys: [UnsafePointer<CChar>?] = [key, timeout, nil], values: [UnsafePointer<CChar>?] = [dsn, value, nil]
                return keys.withUnsafeBufferPointer { keys in values.withUnsafeBufferPointer { values in PQconnectdbParams(keys.baseAddress, values.baseAddress, 1) } }
            } } }
        }
        guard let db else { throw MessageArchiveError.database }
        defer { PQfinish(db) }
        guard PQstatus(db) == CONNECTION_OK else { throw MessageArchiveError.database }
        PQsetNoticeProcessor(db, { _, _ in }, nil)
        guard let setup = PQexec(db, "SET statement_timeout TO '15s'") else { throw MessageArchiveError.database }
        let ready = PQresultStatus(setup) == PGRES_COMMAND_OK; PQclear(setup)
        guard ready else { throw MessageArchiveError.database }
        let result = schema.withCString { name in
            let values: [UnsafePointer<CChar>?] = [name]
            let sql = archiveOnly
                ? "SELECT 1 FROM pg_namespace n WHERE n.nspname=$1 AND EXISTS(SELECT 1 FROM pg_class c WHERE c.relnamespace=n.oid AND c.relname='archive_metadata' AND c.relkind='r')"
                : "SELECT 1 FROM pg_namespace WHERE nspname=$1"
            return values.withUnsafeBufferPointer { values in PQexecParams(db, sql, 1, nil, values.baseAddress, nil, nil, 0) }
        }
        guard let result else { throw MessageArchiveError.database }
        defer { PQclear(result) }
        guard PQresultStatus(result) == PGRES_TUPLES_OK else { throw MessageArchiveError.database }
        return PQntuples(result) > 0
    }
}

extension ArchiveBackup {
    static func restoreVerified(_ verified: ArchiveBackupVerified, connectionString: String, schema: String,
                                storage: (any ArchiveBackupObjectStorage)?, keys: ArchiveBackupKeys,
                                currentPolicy: @Sendable (MessageArchiveIdentity) async throws -> Bool?,
                                currentOffPolicies: @Sendable () async throws -> [MessageArchiveIdentity]) async throws -> ArchiveBackupSummary {
        let header = verified.header
        if let existing = try keys.lookup(header.vaultID), existing != header.rootKey { throw ArchiveBackupError.conflict }
        try ArchiveBackupDestination.requireNewSchema(connectionString: connectionString, schema: schema)
        if !verified.objects.isEmpty {
            guard let storage, ArchiveBackupCryptography.validHash(storage.storageID) else { throw ArchiveBackupError.storageUnavailable }
        }
        let crypto = try ArchiveBackupCryptography(vaultID: header.vaultID, rootKey: header.rootKey)
        var missing: [ArchiveBackupObject] = [], disabled: [String: MessageArchiveIdentity] = [:]
        var current: [String: Bool] = [:], hasMissingOff = false
        var retainedPolicies = 0
        func preserveOff(_ identities: [MessageArchiveIdentity]) throws {
            guard identities.count <= ArchiveBackupLimits.objects else { throw ArchiveBackupError.invalid }
            for identity in identities {
                let fields = [identity.service, identity.accountID, identity.conversationID]
                guard fields.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw ArchiveBackupError.invalid }
                let scope = crypto.token(fields)
                if disabled[scope] == nil {
                    retainedPolicies += fields.reduce(128) { $0 + $1.utf8.count }
                    guard retainedPolicies <= ArchiveBackupLimits.metadata else { throw ArchiveBackupError.invalid }
                }
                disabled[scope] = identity; current[scope] = false
            }
        }
        try preserveOff(await currentOffPolicies())
        for object in verified.objects {
            try Task.checkCancellation()
            let record = object.record, identity = record.identity
            let scope = crypto.token([identity.service, identity.accountID, identity.conversationID])
            if current[scope] == nil { current[scope] = try await currentPolicy(identity) ?? true }
            let denied = current[scope] == false
            if denied { disabled[scope] = identity }
            guard let storage else { throw ArchiveBackupError.storageUnavailable }
            if let receipt = try await storage.head(key: record.objectKey) {
                guard receipt.key == record.objectKey, receipt.byteCount == record.byteCount, receipt.sha256 == record.sha256 else { throw ArchiveBackupError.conflict }
                try await verifyDestinationObject(record, storage: storage, workspace: verified.workspace.directory)
            } else {
                if !object.mayCopy || denied { hasMissingOff = true }
                missing.append(object)
            }
        }
        guard !hasMissingOff else { throw ArchiveBackupError.disabledObjectMissing }
        for object in missing {
            try Task.checkCancellation()
            let record = object.record
            guard try await currentPolicy(record.identity) != false else { throw ArchiveBackupError.policyChanged }
            try Task.checkCancellation()
            guard let storage else { throw ArchiveBackupError.storageUnavailable }
            let receipt = try await storage.put(file: verified.objectDirectory.appendingPathComponent(ArchiveBackupFormat.objectName(record.id)),
                key: record.objectKey, sha256: record.sha256, byteCount: record.byteCount)
            guard receipt.key == record.objectKey, receipt.sha256 == record.sha256, receipt.byteCount == record.byteCount else { throw ArchiveBackupError.integrity }
            try await verifyDestinationObject(record, storage: storage, workspace: verified.workspace.directory)
        }
        for object in verified.objects {
            let identity = object.record.identity
            if try await currentPolicy(identity) == false {
                disabled[crypto.token([identity.service, identity.accountID, identity.conversationID])] = identity
            }
        }
        try preserveOff(await currentOffPolicies())
        try Task.checkCancellation()
        let bootstrap = ArchiveBackupBootstrap(verified: verified, destinationStorageID: storage?.storageID,
            disabledPolicies: Array(disabled.values), installKey: keys.install)
        _ = try MessageArchiveStore(connectionString: connectionString, schema: schema, keyProvider: { id, _ in
            guard id == header.vaultID else { throw ArchiveBackupError.integrity }; return header.rootKey
        }, restoring: bootstrap)
        return header.summary
    }
    private static func verifyDestinationObject(_ record: ArchiveFileRecord, storage: any ArchiveBackupObjectStorage,
                                                workspace: ArchiveBackupDirectory) async throws {
        let name = "target-\(UUID().uuidString.lowercased())", path = workspace.url.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: path) }
        try await storage.download(key: record.objectKey, to: path, sha256: record.sha256, byteCount: record.byteCount)
        guard try workspace.file(name).sha256(expectedCount: record.byteCount) == record.sha256 else { throw ArchiveBackupError.integrity }
    }
}
