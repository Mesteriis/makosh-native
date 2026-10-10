// SPDX-License-Identifier: GPL-3.0-or-later
// Makosh adaptation for pinned Telegram-iOS a24bbe45f9861f736a79916a50898512f751e0dc.
import Foundation

public struct MakoshMessageJournalEntry {
    public let sequence: Int64
    public let eventID: UUID
    public let capturedAt: Double
    public let id: MessageId
    public let timestamp: Int32
    public let text: String
    public let authorId: PeerId?
    public let flags: MessageFlags
    public let attributes: [MessageAttribute]
    public let media: [Media]
    /// Physical cache removal; no claim about remote deletion cause.
    public let removed: Bool
}

public enum MakoshMessageJournalError: Error {
    case unavailable, corrupt, invalidAcknowledgement
}

// No caches: the sequence and entries participate in their caller's ValueBox transaction.
final class MakoshMessageJournal {
    static let entries = ValueBoxTable(id: 9001, keyType: .binary, compactValuesOnCreation: false)
    static let metadata = ValueBoxTable(id: 9002, keyType: .binary, compactValuesOnCreation: false)
    private let valueBox: ValueBox
    init(valueBox: ValueBox) { self.valueBox = valueBox }
    private static func key(_ sequence: Int64) -> ValueBoxKey {
        let key = ValueBoxKey(length: 8); key.setInt64(0, value: sequence); return key
    }
    private struct Envelope: Codable {
        let version: Int
        let sequence: Int64
        let eventID: UUID
        let capturedAt: Double
        let peer: Int64
        let namespace: Int32
        let message: Int32
        let timestamp: Int32
        let text: String
        let author: Int64?
        let flags: UInt32
        let attributes: [Data]
        let media: [Data]
        let removed: Bool
    }
    private static func encodeObject(_ object: PostboxCoding) -> Data {
        let encoder = PostboxEncoder(); encoder.encodeRootObject(object); return encoder.makeData()
    }
    func append(id: MessageId, timestamp: Int32, text: String, authorId: PeerId?, flags: MessageFlags,
                attributes: [MessageAttribute], media: [Media], removed: Bool) {
        let metadataKey = Self.key(0)
        let sequence: Int64
        if let previous = valueBox.get(Self.metadata, key: metadataKey) {
            guard previous.length == 8 else { preconditionFailure("Makosh journal metadata corrupt") }
            var last: Int64 = 0; previous.read(&last, offset: 0, length: 8)
            guard last >= 0, last < Int64.max - 1 else { preconditionFailure("Makosh journal sequence exhausted") }
            sequence = last + 1
        } else { sequence = 1 }
        let envelope = Envelope(version: 1, sequence: sequence, eventID: UUID(), capturedAt: Date().timeIntervalSince1970, peer: id.peerId.toInt64(),
            namespace: id.namespace, message: id.id, timestamp: timestamp, text: text,
            author: authorId?.toInt64(), flags: flags.rawValue,
            attributes: attributes.map { Self.encodeObject($0) }, media: media.map { Self.encodeObject($0) }, removed: removed)
        let bytes: Data
        do { bytes = try JSONEncoder().encode(envelope) }
        catch { preconditionFailure("Makosh journal encoding failed") }
        // Fail-stop, never truncate/drop events. ValueBox's own void IO/commit errors remain upstream limitations.
        valueBox.set(Self.entries, key: Self.key(sequence), value: MemoryBuffer(data: bytes))
        var stored = sequence
        let buffer = WriteBuffer(); buffer.write(&stored, offset: 0, length: 8)
        valueBox.set(Self.metadata, key: metadataKey, value: buffer)
    }
    func read(limit: Int) throws -> [MakoshMessageJournalEntry] {
        let bound = min(1000, max(0, limit))
        guard bound > 0 else { return [] }
        var result: [MakoshMessageJournalEntry] = []
        var failure: Error?
        valueBox.range(Self.entries, start: Self.key(0), end: Self.key(Int64.max), values: { key, buffer in
            do {
                guard key.length == 8 else { throw MakoshMessageJournalError.corrupt }
                let value = try JSONDecoder().decode(Envelope.self, from: buffer.makeData())
                guard value.version == 1, value.sequence > 0, value.sequence == key.getInt64(0), value.capturedAt.isFinite, value.capturedAt > 0 else {
                    throw MakoshMessageJournalError.corrupt
                }
                var attributes: [MessageAttribute] = []
                for data in value.attributes {
                    guard let object = PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as? MessageAttribute else {
                        throw MakoshMessageJournalError.corrupt
                    }
                    attributes.append(object)
                }
                var media: [Media] = []
                for data in value.media {
                    guard let object = PostboxDecoder(buffer: MemoryBuffer(data: data)).decodeRootObject() as? Media else {
                        throw MakoshMessageJournalError.corrupt
                    }
                    media.append(object)
                }
                result.append(MakoshMessageJournalEntry(sequence: value.sequence, eventID: value.eventID,
                    capturedAt: value.capturedAt, id: MessageId(peerId: PeerId(value.peer), namespace: value.namespace, id: value.message),
                    timestamp: value.timestamp, text: value.text, authorId: value.author.map(PeerId.init),
                    flags: MessageFlags(rawValue: value.flags), attributes: attributes, media: media, removed: value.removed))
                return result.count < bound
            } catch { failure = MakoshMessageJournalError.corrupt; return false }
        }, limit: bound)
        if let failure { throw failure }
        return result
    }
    func acknowledge(sequences: [Int64]) throws {
        guard sequences.count <= 1000 else { throw MakoshMessageJournalError.invalidAcknowledgement }
        let unique = Set(sequences)
        guard unique.allSatisfy({ $0 > 0 && valueBox.exists(Self.entries, key: Self.key($0)) }) else {
            throw MakoshMessageJournalError.invalidAcknowledgement
        }
        for sequence in unique { valueBox.remove(Self.entries, key: Self.key(sequence), secure: true) }
    }
}
