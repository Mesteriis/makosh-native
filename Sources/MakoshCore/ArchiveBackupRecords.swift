import Foundation
import CryptoKit

enum ArchiveBackupLimits {
    static let rows = 1_000_000, objects = 100_000, metadata = 64 * 1024 * 1024
    static let part = 32 * 1024 * 1024, parts = 1024, frame = 8 * 1024 * 1024
}
enum ArchiveBackupTable: String, Codable, CaseIterable {
    case metadata = "archive_metadata", policies = "archive_conversation_file_policy"
    case events = "archive_events", receipts = "archive_receipts", files = "archive_file_events"
    case aliases = "archive_storage_aliases"
    var columns: [String] {
        switch self {
        case .metadata: ["version", "vault", "key_check"]
        case .policies: ["stream_token", "ciphertext"]
        case .events: ["sequence", "observation", "account_token", "stream_token", "message_token", "event_digest", "ciphertext"]
        case .receipts: ["observation", "digest"]
        case .files: ["sequence", "object", "state", "attachment_token", "ciphertext"]
        case .aliases: ["source_storage", "destination_storage", "ciphertext"]
        }
    }
    var order: String {
        switch self {
        case .metadata: "id"
        case .policies: "stream_token COLLATE \"C\""
        case .events, .files: "sequence"
        case .receipts: "observation"
        case .aliases: "source_storage COLLATE \"C\",destination_storage COLLATE \"C\""
        }
    }
}
struct ArchiveBackupRow: Codable { let table: ArchiveBackupTable; let values: [String] }
struct ArchiveBackupPolicy: Codable {
    let service: String, accountID: String, conversationID: String
    let enabled: Bool
}
struct ArchiveBackupStorageAlias: Codable {
    let vaultID: UUID
    let source: String, destination: String
}
struct ArchiveBackupObject: Sendable {
    let record: ArchiveFileRecord
    let mayCopy: Bool
}

struct ArchiveBackupCryptography {
    let vaultID: UUID
    let encryption: SymmetricKey, lookup: SymmetricKey
    init(vaultID: UUID, rootKey: Data) throws {
        guard rootKey.count == 32 else { throw ArchiveBackupError.keyUnavailable }
        self.vaultID = vaultID
        encryption = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: rootKey), salt: Data(vaultID.uuidString.utf8), info: Data("makosh-archive-aes-v1".utf8), outputByteCount: 32)
        lookup = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: rootKey), salt: Data(vaultID.uuidString.utf8), info: Data("makosh-archive-hmac-v1".utf8), outputByteCount: 32)
    }
    var fileKey: Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: encryption, salt: Data(vaultID.uuidString.utf8), info: Data("makosh-file-vault-v1".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
    }
    func binding(_ token: String, _ sequence: Int64 = 0) -> Data { Data("\(vaultID.uuidString)|1|\(token)|\(sequence)".utf8) }
    func open(_ value: String, token: String, sequence: Int64 = 0) throws -> Data {
        guard let combined = Data(base64Encoded: value) else { throw ArchiveBackupError.integrity }
        do { return try AES.GCM.open(.init(combined: combined), using: encryption, authenticating: binding(token, sequence)) }
        catch { throw ArchiveBackupError.integrity }
    }
    func seal(_ data: Data, token: String) throws -> String {
        guard let combined = try AES.GCM.seal(data, using: encryption, authenticating: binding(token)).combined else { throw ArchiveBackupError.integrity }
        return combined.base64EncodedString()
    }
    func mac(_ data: Data) -> String { Data(HMAC<SHA256>.authenticationCode(for: data, using: lookup)).base64EncodedString() }
    func token(_ fields: [String]) -> String {
        mac(fields.reduce(into: Data()) { bytes, value in bytes.append(Data("\(value.utf8.count):".utf8)); bytes.append(Data(value.utf8)) })
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validHash(_ value: String) -> Bool { ArchiveFileRecord.validHash(value) }
}

/// Validates every preserved row before any target write; no message bodies escape.
final class ArchiveBackupRowValidator {
    let crypto: ArchiveBackupCryptography
    private(set) var counts = Dictionary(uniqueKeysWithValues: ArchiveBackupTable.allCases.map { ($0.rawValue, Int64(0)) })
    private var tablePosition = 0, rowCount = 0, budget = 0
    private var eventSequence: Int64 = 0, fileSequence: Int64 = 0
    private var previousReceipt = "", previousPolicy = "", previousAlias = ""
    private var eventReceipts: [UUID: String] = [:]
    private var policies: [String: ArchiveBackupPolicy] = [:]
    private var pending: [UUID: String] = [:]
    private var stored: [UUID: ArchiveFileRecord] = [:]
    private(set) var aliases = Set<String>()
    init(vaultID: UUID, rootKey: Data) throws { crypto = try .init(vaultID: vaultID, rootKey: rootKey) }
    private func charge(_ count: Int) throws {
        guard count >= 0, count <= ArchiveBackupLimits.metadata - budget else { throw ArchiveBackupError.invalid }; budget += count
    }
    private func identifier(_ value: String) throws -> UUID {
        guard let id = UUID(uuidString: value), id.uuidString.lowercased() == value else { throw ArchiveBackupError.integrity }; return id
    }
    private func fields(_ fields: [String]) -> Bool { fields.allSatisfy { !$0.isEmpty && $0.utf8.count <= 1024 } }
    func accept(_ row: ArchiveBackupRow) throws {
        guard let position = ArchiveBackupTable.allCases.firstIndex(of: row.table), position >= tablePosition,
              row.values.count == row.table.columns.count, rowCount < ArchiveBackupLimits.rows else { throw ArchiveBackupError.invalid }
        tablePosition = position; rowCount += 1; counts[row.table.rawValue, default: 0] += 1
        for (index, value) in row.values.enumerated() {
            let limit = ["ciphertext", "key_check"].contains(row.table.columns[index]) ? 6 * 1024 * 1024 : 2048
            guard value.utf8.count <= limit, !value.utf8.contains(0) else { throw ArchiveBackupError.invalid }
        }
        let values = row.values
        switch row.table {
        case .metadata:
            guard counts[row.table.rawValue] == 1, values[0] == "1", try identifier(values[1]) == crypto.vaultID,
                  try crypto.open(values[2], token: "key") == Data("archive-key-check-v1".utf8) else { throw ArchiveBackupError.integrity }
        case .policies:
            guard values[0] > previousPolicy else { throw ArchiveBackupError.integrity }; previousPolicy = values[0]
            let payload = try crypto.open(values[1], token: "conversation-file-policy-\(values[0])")
            guard payload.count <= 16384 else { throw ArchiveBackupError.invalid }
            let policy = try JSONDecoder().decode(ArchiveBackupPolicy.self, from: payload)
            guard fields([policy.service, policy.accountID, policy.conversationID]),
                  crypto.token([policy.service, policy.accountID, policy.conversationID]) == values[0] else { throw ArchiveBackupError.integrity }
            try charge(payload.count + 128); policies[values[0]] = policy
        case .events:
            guard let sequence = Int64(values[0]), sequence > eventSequence, String(sequence) == values[0] else { throw ArchiveBackupError.integrity }
            eventSequence = sequence
            let id = try identifier(values[1]), payload = try crypto.open(values[6], token: values[4], sequence: sequence)
            guard payload.count <= 4 * 1024 * 1024 else { throw ArchiveBackupError.invalid }
            let observation = try JSONDecoder().decode(MessageArchiveObservation.self, from: payload), identity = observation.identity
            guard observation.id == id, eventReceipts[id] == nil, observation.observedAt.timeIntervalSince1970.isFinite,
                  fields([identity.service, identity.accountID, identity.conversationID, identity.messageID]),
                  values[2] == crypto.token([identity.service, identity.accountID]),
                  values[3] == crypto.token([identity.service, identity.accountID, identity.conversationID]),
                  values[4] == crypto.token([identity.service, identity.accountID, identity.conversationID, identity.messageID]),
                  values[5] == crypto.mac(try ArchiveBackupCryptography.encode(observation.event)) else { throw ArchiveBackupError.integrity }
            try charge(128); eventReceipts[id] = crypto.mac(payload)
        case .receipts:
            let id = try identifier(values[0])
            guard values[0] > previousReceipt, Data(base64Encoded: values[1])?.count == 32 else { throw ArchiveBackupError.integrity }
            previousReceipt = values[0]
            if let expected = eventReceipts.removeValue(forKey: id), expected != values[1] { throw ArchiveBackupError.integrity }
        case .files:
            guard let sequence = Int64(values[0]), sequence > fileSequence, String(sequence) == values[0] else { throw ArchiveBackupError.integrity }
            fileSequence = sequence
            let id = try identifier(values[1]), payload = try crypto.open(values[4], token: "file-\(id.uuidString)-\(values[2])")
            guard payload.count <= 16384 else { throw ArchiveBackupError.invalid }
            var record = try JSONDecoder().decode(ArchiveFileRecord.self, from: payload)
            try record.validate(vaultID: crypto.vaultID)
            let identity = record.identity
            guard record.id == id, record.state.rawValue == values[2], record.state != .local,
                  values[3] == crypto.token([identity.service, identity.accountID, identity.conversationID, identity.messageID, record.attachment.id]) else { throw ArchiveBackupError.integrity }
            if record.state == .stored {
                guard stored[id] == nil, stored.count < ArchiveBackupLimits.objects else { throw ArchiveBackupError.invalid }
                try charge(payload.count + 256); stored[id] = record
            } else {
                guard pending[id] == nil, pending.count < ArchiveBackupLimits.objects else { throw ArchiveBackupError.invalid }
                record.state = .pending; try charge(128)
                pending[id] = ArchiveBackupCryptography.hash(try ArchiveBackupCryptography.encode(record))
            }
        case .aliases:
            let pair = values[0] + "\0" + values[1]
            guard ArchiveBackupCryptography.validHash(values[0]), ArchiveBackupCryptography.validHash(values[1]),
                  values[0] != values[1], pair > previousAlias else { throw ArchiveBackupError.integrity }
            previousAlias = pair
            let payload = try crypto.open(values[2], token: "storage-alias-\(values[0])-\(values[1])")
            guard payload.count <= 1024 else { throw ArchiveBackupError.invalid }
            let alias = try JSONDecoder().decode(ArchiveBackupStorageAlias.self, from: payload)
            guard alias.vaultID == crypto.vaultID, alias.source == values[0], alias.destination == values[1] else { throw ArchiveBackupError.integrity }
            try charge(pair.utf8.count + 128); aliases.insert(pair)
        }
    }
    func finish() throws -> [ArchiveBackupObject] {
        guard counts[ArchiveBackupTable.metadata.rawValue] == 1, eventReceipts.isEmpty, pending.count == stored.count else { throw ArchiveBackupError.incomplete }
        return try stored.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { record in
            var normalized = record; normalized.state = .pending
            guard pending[record.id] == ArchiveBackupCryptography.hash(try ArchiveBackupCryptography.encode(normalized)) else { throw ArchiveBackupError.incomplete }
            let identity = record.identity
            let scope = crypto.token([identity.service, identity.accountID, identity.conversationID])
            let defaultEnabled: Bool
            switch record.purpose {
            case let .conversation(enabled)?, let .outgoing(enabled)?: defaultEnabled = enabled
            case .preparation?, nil: defaultEnabled = false
            }
            return .init(record: record, mayCopy: policies[scope]?.enabled ?? defaultEnabled)
        }
    }
}

final class ArchiveBackupRecordReader {
    private let file: ArchiveBackupFile
    init(_ file: ArchiveBackupFile) throws { self.file = file; try file.rewind() }
    func next() throws -> ArchiveBackupRow? {
        let prefix = try file.read(4)
        if prefix.isEmpty { try file.stable(); return nil }
        guard prefix.count == 4 else { throw ArchiveBackupError.integrity }
        let count = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...ArchiveBackupLimits.frame).contains(count) else { throw ArchiveBackupError.invalid }
        return try JSONDecoder().decode(ArchiveBackupRow.self, from: file.readExactly(count))
    }
    static func frame(_ row: ArchiveBackupRow) throws -> Data {
        let data = try ArchiveBackupCryptography.encode(row)
        guard !data.isEmpty, data.count <= ArchiveBackupLimits.frame else { throw ArchiveBackupError.invalid }
        var count = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &count) { Data($0) } + data
    }
}
