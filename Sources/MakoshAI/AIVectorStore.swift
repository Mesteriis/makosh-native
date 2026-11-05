import Foundation
import MakoshCore

public struct AIIndexGeneration: Codable, Equatable, Sendable {
    public let id: Int64
    public let connectionID: UUID
    public let model: String
    public let dimensions: Int
    public var ready: Bool
}

/// A searchable piece of permitted Makosh data. Text and source references
/// are encrypted at rest; only the vector is stored in the clear.
public struct AIChunk: Codable, Sendable, Equatable {
    public let id: String
    public let scope: AIAccessScope
    public let messages: [MessageArchiveIdentity]
    public let authors: [ServiceIdentity]
    public let text: String
    public let date: Date
    public let title: String
    public init(
        id: String, scope: AIAccessScope, messages: [MessageArchiveIdentity], authors: [ServiceIdentity], text: String, date: Date,
        title: String
    ) {
        self.id = id
        self.scope = scope
        self.messages = messages
        self.authors = authors
        self.text = text
        self.date = date
        self.title = title
    }
}

public enum AIIndexedVersion: Sendable, Equatable {
    case unknown, current, outdated
}

public struct AIChunkMatch: Sendable, Equatable {
    public let chunk: AIChunk
    public let distance: Double
}

/// pgvector index of AI chunks. Each embedding model gets its own
/// generation with a partial HNSW expression index; generations never mix.
/// Uses its own connection so it never shares one with `AIRepository`.
public actor AIVectorStore {
    /// HNSW supports at most 2000 dimensions for `vector`.
    public static let maximumDimensions = 2000
    private let keyProvider: @Sendable (UUID, Bool) throws -> Data
    private let extensionName: String
    private var database: AIPostgres?
    private var prepared = false

    public init(keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data = MessageArchiveKeychain.open) {
        self.init(keyProvider: keyProvider, extensionName: "vector")
    }
    init(keyProvider: @escaping @Sendable (UUID, Bool) throws -> Data, extensionName: String) {
        self.keyProvider = keyProvider
        self.extensionName = extensionName
    }

    public func open(configuration: ContactWorkspaceConfiguration) throws {
        guard database == nil else { return }
        let db = try AIPostgres(configuration: configuration)
        try db.open(keyProvider: keyProvider)
        database = db
    }

    public func close() {
        database?.close()
        database = nil
        prepared = false
    }

    /// Creates the extension and tables when possible; false means RAG is
    /// unavailable while chat keeps working.
    public func available() throws -> Bool {
        if prepared { return true }
        let db = try db()
        guard extensionName.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }) else { return false }
        do { try db.query("CREATE EXTENSION IF NOT EXISTS \"\(extensionName)\"") } catch { return false }
        try db.transaction {
            try db.query("SELECT pg_advisory_xact_lock(hashtext('makosh-ai-vectors'),hashtext($1))", [db.configuration.schema])
            try db.query(
                "CREATE TABLE IF NOT EXISTS \(db.prefix)ai_index_generations(id BIGSERIAL PRIMARY KEY,lookup TEXT NOT NULL UNIQUE,dimensions INTEGER NOT NULL,ready BOOLEAN NOT NULL DEFAULT FALSE,ciphertext TEXT NOT NULL)"
            )
            try db.query(
                "CREATE TABLE IF NOT EXISTS \(db.prefix)ai_chunks(generation BIGINT NOT NULL REFERENCES \(db.prefix)ai_index_generations(id) ON DELETE CASCADE,chunk_token TEXT NOT NULL,scope_token TEXT NOT NULL,author_tokens TEXT[] NOT NULL,message_tokens TEXT[] NOT NULL,embedding vector NOT NULL,ciphertext TEXT NOT NULL,PRIMARY KEY(generation,chunk_token))"
            )
            try db.query("CREATE INDEX IF NOT EXISTS ai_chunks_scope ON \(db.prefix)ai_chunks(scope_token)")
            try db.query("CREATE INDEX IF NOT EXISTS ai_chunks_authors ON \(db.prefix)ai_chunks USING gin(author_tokens)")
            try db.query("CREATE INDEX IF NOT EXISTS ai_chunks_messages ON \(db.prefix)ai_chunks USING gin(message_tokens)")
            // The newest version of each message the index reflects, as a keyed digest of its indexed content.
            try db.query(
                "CREATE TABLE IF NOT EXISTS \(db.prefix)ai_index_messages(message_token TEXT PRIMARY KEY,scope_token TEXT NOT NULL,sequence BIGINT NOT NULL,digest TEXT NOT NULL)"
            )
            try db.query("CREATE INDEX IF NOT EXISTS ai_index_messages_scope ON \(db.prefix)ai_index_messages(scope_token)")
        }
        prepared = true
        return true
    }

    public func generation(connectionID: UUID, model: String, dimensions: Int) throws -> AIIndexGeneration {
        guard (1...Self.maximumDimensions).contains(dimensions) else { throw AIFailure.dimensionsTooLarge }
        let db = try preparedDatabase()
        let lookup = try db.token(["generation", connectionID.uuidString, model, String(dimensions)])
        return try db.transaction {
            if let row = try db.query("SELECT id,ready,ciphertext FROM \(db.prefix)ai_index_generations WHERE lookup=$1", [lookup]).first {
                return try decodeGeneration(row, db: db)
            }
            let value = GenerationRecord(connectionID: connectionID, model: model, dimensions: dimensions)
            let rows = try db.query(
                "INSERT INTO \(db.prefix)ai_index_generations(lookup,dimensions,ciphertext) VALUES($1,$2::int,$3) RETURNING id",
                [lookup, String(dimensions), try db.seal(value, token: "generation:" + lookup)])
            guard let id = rows.first.flatMap({ Int64($0[0]) }) else { throw AIFailure.storage }
            try db.query(
                "CREATE INDEX IF NOT EXISTS ai_chunks_hnsw_\(id) ON \(db.prefix)ai_chunks USING hnsw ((embedding::vector(\(dimensions))) vector_cosine_ops) WHERE generation=\(id)"
            )
            return AIIndexGeneration(id: id, connectionID: connectionID, model: model, dimensions: dimensions, ready: false)
        }
    }

    public func activeGeneration() throws -> AIIndexGeneration? {
        let db = try preparedDatabase()
        return try db.query("SELECT id,ready,ciphertext FROM \(db.prefix)ai_index_generations WHERE ready ORDER BY id DESC LIMIT 1").first
            .map { try decodeGeneration($0, db: db) }
    }

    /// Makes a generation the answering one and drops every older one.
    public func markReady(_ id: Int64) throws {
        let db = try preparedDatabase()
        try db.transaction {
            try db.query("UPDATE \(db.prefix)ai_index_generations SET ready=TRUE WHERE id=$1::bigint", [String(id)])
            for row in try db.query("SELECT id FROM \(db.prefix)ai_index_generations WHERE id<$1::bigint", [String(id)]) {
                guard let old = Int64(row[0]) else { throw AIFailure.storage }
                try db.query("DROP INDEX IF EXISTS \(db.prefix)ai_chunks_hnsw_\(old)")
            }
            try db.query("DELETE FROM \(db.prefix)ai_index_generations WHERE id<$1::bigint", [String(id)])
        }
    }

    public func contains(_ chunkIDs: [String], generation: Int64) throws -> Set<String> {
        guard !chunkIDs.isEmpty else { return [] }
        let db = try preparedDatabase()
        let tokens = try Dictionary(chunkIDs.map { (try db.token(["chunk", $0]), $0) }, uniquingKeysWith: { first, _ in first })
        let rows = try db.query(
            "SELECT chunk_token FROM \(db.prefix)ai_chunks WHERE generation=$1::bigint AND chunk_token=ANY($2::text[])",
            [String(generation), Self.array(Array(tokens.keys))])
        return Set(rows.compactMap { tokens[$0[0]] })
    }

    public func insert(_ chunks: [(AIChunk, [Float])], generation: Int64) throws {
        guard !chunks.isEmpty else { return }
        let db = try preparedDatabase()
        try db.transaction {
            guard
                let dimensions = try db.query(
                    "SELECT dimensions FROM \(db.prefix)ai_index_generations WHERE id=$1::bigint", [String(generation)]
                )
                .first.flatMap({ Int($0[0]) })
            else { throw AIFailure.storage }
            for (chunk, vector) in chunks {
                guard vector.count == dimensions, vector.allSatisfy(\.isFinite) else { throw AIFailure.malformedResponse }
                let token = try db.token(["chunk", chunk.id])
                try db.query(
                    "INSERT INTO \(db.prefix)ai_chunks(generation,chunk_token,scope_token,author_tokens,message_tokens,embedding,ciphertext) VALUES($1::bigint,$2,$3,$4::text[],$5::text[],$6::vector,$7) ON CONFLICT(generation,chunk_token) DO NOTHING",
                    [
                        String(generation), token, try scopeToken(chunk.scope, db: db),
                        Self.array(try chunk.authors.map { try authorToken($0, db: db) }),
                        Self.array(try chunk.messages.map { try messageToken($0, db: db) }), Self.vector(vector),
                        try db.seal(chunk, token: "chunk:" + token),
                    ])
            }
        }
    }

    public func delete(scope: AIAccessScope) throws {
        let db = try preparedDatabase()
        let token = try scopeToken(scope, db: db)
        try db.transaction {
            try db.query("DELETE FROM \(db.prefix)ai_chunks WHERE scope_token=$1", [token])
            try db.query("DELETE FROM \(db.prefix)ai_index_messages WHERE scope_token=$1", [token])
        }
    }

    public func delete(author: ServiceIdentity) throws {
        let db = try preparedDatabase()
        try db.query("DELETE FROM \(db.prefix)ai_chunks WHERE author_tokens && $1::text[]", [Self.array([try authorToken(author, db: db)])])
    }

    public func hasMessage(_ message: MessageArchiveIdentity) throws -> Bool {
        let db = try preparedDatabase()
        return try !db.query(
            "SELECT 1 FROM \(db.prefix)ai_chunks WHERE message_tokens && $1::text[] LIMIT 1",
            [Self.array([try messageToken(message, db: db)])]
        ).isEmpty
    }

    public func delete(message: MessageArchiveIdentity) throws {
        let db = try preparedDatabase()
        let token = try messageToken(message, db: db)
        try db.transaction {
            try db.query("DELETE FROM \(db.prefix)ai_chunks WHERE message_tokens && $1::text[]", [Self.array([token])])
            try db.query("DELETE FROM \(db.prefix)ai_index_messages WHERE message_token=$1", [token])
        }
    }

    /// Whether a journal version still needs indexing: nil for a message the
    /// index has not seen, otherwise the stored version is compared so an
    /// older or content-identical version (a read or flag change) is skipped.
    public func indexedVersion(of item: AIIndexItem) throws -> AIIndexedVersion {
        let db = try preparedDatabase()
        guard
            let row = try db.query(
                "SELECT sequence,digest FROM \(db.prefix)ai_index_messages WHERE message_token=$1",
                [try messageToken(item.identity, db: db)]
            ).first, let sequence = Int64(row[0])
        else { return .unknown }
        if try sequence >= item.sequence || row[1] == digest(item, db: db) { return .current }
        return .outdated
    }

    /// Records the versions just reflected in the index; a newer stored version is kept.
    public func recordIndexed(_ items: [AIIndexItem]) throws {
        guard !items.isEmpty else { return }
        let db = try preparedDatabase()
        try db.transaction {
            for item in items {
                try db.query(
                    "INSERT INTO \(db.prefix)ai_index_messages AS m VALUES($1,$2,$3::bigint,$4) ON CONFLICT(message_token) DO UPDATE SET scope_token=excluded.scope_token,sequence=excluded.sequence,digest=excluded.digest WHERE m.sequence<excluded.sequence",
                    [
                        try messageToken(item.identity, db: db), try scopeToken(item.scope, db: db), String(item.sequence),
                        try digest(item, db: db),
                    ])
            }
        }
    }

    public func count(generation: Int64) throws -> Int {
        let db = try preparedDatabase()
        return try db.query("SELECT count(*) FROM \(db.prefix)ai_chunks WHERE generation=$1::bigint", [String(generation)]).first.flatMap {
            Int($0[0])
        } ?? 0
    }

    func chunks(generation: Int64) throws -> [AIChunk] {
        let db = try preparedDatabase()
        return try db.query(
            "SELECT chunk_token,ciphertext FROM \(db.prefix)ai_chunks WHERE generation=$1::bigint ORDER BY chunk_token LIMIT 10000",
            [String(generation)]
        ).map { try db.decode($0[1], token: "chunk:" + $0[0]) }
    }

    public func search(_ vector: [Float], generation: Int64, limit: Int, maxDistance: Double) throws -> [AIChunkMatch] {
        let db = try preparedDatabase()
        guard (1...50).contains(limit),
            let dimensions = try db.query(
                "SELECT dimensions FROM \(db.prefix)ai_index_generations WHERE id=$1::bigint", [String(generation)]
            )
            .first.flatMap({ Int($0[0]) }),
            vector.count == dimensions, vector.allSatisfy(\.isFinite)
        else { throw AIFailure.invalidConfiguration }
        let expression = "(embedding::vector(\(dimensions)))"
        let rows = try db.query(
            "SELECT chunk_token,ciphertext,\(expression) <=> $2::vector(\(dimensions)) FROM \(db.prefix)ai_chunks WHERE generation=$1::bigint ORDER BY \(expression) <=> $2::vector(\(dimensions)) LIMIT \(limit)",
            [String(generation), Self.vector(vector)])
        return try rows.compactMap { row in
            guard let distance = Double(row[2]) else { throw AIFailure.storage }
            guard distance <= maxDistance else { return nil }
            return AIChunkMatch(chunk: try db.decode(row[1], token: "chunk:" + row[0]), distance: distance)
        }
    }

    private struct GenerationRecord: Codable {
        let connectionID: UUID
        let model: String
        let dimensions: Int
    }
    private func decodeGeneration(_ row: [String], db: AIPostgres) throws -> AIIndexGeneration {
        guard let id = Int64(row[0]) else { throw AIFailure.storage }
        let lookup = try db.query("SELECT lookup FROM \(db.prefix)ai_index_generations WHERE id=$1::bigint", [row[0]]).first?[0] ?? ""
        let record: GenerationRecord = try db.decode(row[2], token: "generation:" + lookup)
        return AIIndexGeneration(
            id: id, connectionID: record.connectionID, model: record.model, dimensions: record.dimensions, ready: row[1] == "t")
    }
    private func db() throws -> AIPostgres {
        guard let database else { throw AIFailure.storage }
        return database
    }
    private func preparedDatabase() throws -> AIPostgres {
        guard try available() else { throw AIFailure.vectorUnavailable }
        return try db()
    }
    private func scopeToken(_ scope: AIAccessScope, db: AIPostgres) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try db.token(["scope", String(decoding: try encoder.encode(scope), as: UTF8.self)])
    }
    private func authorToken(_ author: ServiceIdentity, db: AIPostgres) throws -> String {
        try db.token(["author", author.service, author.accountID, author.externalID])
    }
    private func digest(_ item: AIIndexItem, db: AIPostgres) throws -> String {
        try db.token([
            "content", item.title, item.text, item.removed ? "removed" : "", item.isOutgoing ? "outgoing" : "",
            item.author.map { "\($0.service)|\($0.accountID)|\($0.externalID)" } ?? "",
        ])
    }
    private func messageToken(_ message: MessageArchiveIdentity, db: AIPostgres) throws -> String {
        try db.token(["message", message.service, message.accountID, message.conversationID, message.messageID])
    }
    /// Tokens are base64, so quoting each element is enough for an array literal.
    private static func array(_ values: [String]) -> String { "{" + values.map { "\"\($0)\"" }.joined(separator: ",") + "}" }
    private static func vector(_ values: [Float]) -> String { "[" + values.map { String($0) }.joined(separator: ",") + "]" }
}
