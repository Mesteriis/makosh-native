import Foundation
import MakoshCore

/// The service journal and Core are separate transactions. Acknowledgement follows Core's idempotent commit.
public actor TeamsArchiveProjection {
    private let configuration: ContactWorkspaceConfiguration
    private let repository: TeamsRepository
    private let keyProvider: @Sendable (UUID, Bool) throws -> Data
    private var archive: MessageArchiveStore?
    public init(configuration: ContactWorkspaceConfiguration, repository: TeamsRepository,
                keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open) {
        self.configuration = configuration; self.repository = repository; self.keyProvider = keyProvider
    }
    public func drain() async throws {
        if archive == nil {
            archive = try MessageArchiveStore(connectionString: configuration.connectionString,
                schema: configuration.archiveSchema ?? configuration.schema, keyProvider: keyProvider)
        }
        guard let archive else { throw TeamsFailure.storage }
        while true {
            try Task.checkCancellation()
            let jobs = try await repository.pendingProjection(limit: 50)
            if jobs.isEmpty { return }
            _ = try archive.append(jobs.map(\.observation))
            for job in jobs { try await repository.acknowledgeProjection(id: job.id) }
            await Task.yield()
        }
    }
    public func page(scope: TeamsScope, before: Int64? = nil) async throws -> [MessageArchiveRecord] {
        try await drain()
        guard let archive else { throw TeamsFailure.storage }
        return try archive.records(service: "teams", accountID: scope.accountID.uuidString,
            conversationID: scope.archiveConversationID, before: before, limit: 50)
    }
    public func export(scope: TeamsScope) async throws -> TeamsFileLease {
        _ = try await repository.validate(scope)
        try await drain() // A failed projection aborts export; retained versions are never silently omitted.
        guard let archive else { throw TeamsFailure.storage }
        let (directory, destination) = try TeamsFileLease.destination(suffix: "jsonl")
        let lease = TeamsFileLease(url: destination, directory: directory)
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TeamsFailure.storage }
            let handle = try FileHandle(forWritingTo: destination); defer { try? handle.close() }
            struct Row: Encodable { let sequence: Int64; let observation: MessageArchiveObservation }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var before: Int64?
            repeat {
                try Task.checkCancellation()
                let records = try archive.records(service: "teams", accountID: scope.accountID.uuidString, conversationID: scope.archiveConversationID, before: before, limit: 50)
                if records.isEmpty { break }
                for record in records {
                    var bytes = try encoder.encode(Row(sequence: record.sequence, observation: record.observation)); bytes.append(10)
                    try handle.write(contentsOf: bytes)
                }
                before = records.last?.sequence
                await Task.yield()
            } while before != nil
            try handle.synchronize()
            return lease
        } catch { await lease.release(); throw error }
    }
}
