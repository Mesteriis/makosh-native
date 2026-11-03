import Foundation
import MakoshCore

struct TelegramPendingUploadArchive: Codable, Equatable, Sendable {
    struct Member: Codable, Equatable, Sendable {
        let itemID: UUID
        let entryName: String

        init(itemID: UUID, entryName: String) { self.itemID = itemID; self.entryName = entryName }

        private enum CodingKeys: String, CodingKey, CaseIterable { case itemID, entryName }
        init(from decoder: any Decoder) throws {
            try requireFields(decoder, expected: CodingKeys.allCases.map(\.rawValue))
            let c = try decoder.container(keyedBy: CodingKeys.self)
            itemID = try c.decode(UUID.self, forKey: .itemID)
            entryName = try c.decode(String.self, forKey: .entryName)
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(itemID, forKey: .itemID); try c.encode(entryName, forKey: .entryName)
        }
    }

    let id: UUID
    let formatVersion: Int
    let file: ArchiveFileRecord
    let members: [Member]

    init(id: UUID, formatVersion: Int = 1, file: ArchiveFileRecord, members: [Member]) {
        self.id = id; self.formatVersion = formatVersion; self.file = file; self.members = members
    }

    static func attachmentID(_ id: UUID) -> String { "archive:" + id.uuidString.lowercased() }

    private enum CodingKeys: String, CodingKey, CaseIterable { case id, formatVersion, file, members }
    init(from decoder: any Decoder) throws {
        try requireFields(decoder, expected: CodingKeys.allCases.map(\.rawValue))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: c, debugDescription: "Unsupported archive format")
        }
        file = try c.decode(ArchiveFileRecord.self, forKey: .file)
        members = try c.decode([Member].self, forKey: .members)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(file, forKey: .file); try c.encode(members, forKey: .members)
    }

    /// Validates the durable manifest only. The held ZIP and source bytes require
    /// separate authenticated capture and streaming archive validation.
    func isValid(identity: MessageArchiveIdentity, items: [TelegramPendingUploadItem]) -> Bool {
        guard formatVersion == 1, id != TelegramPendingUploadDraft.zeroUUID,
              (2...TelegramUploadArchiveLimits.members).contains(items.count), members.count == items.count,
              case .some(.outgoing) = file.purpose,
              file.attachment.kind == "file", file.attachment.name == "Telegram Archive.zip",
              file.plaintextByteCount >= 22, file.plaintextByteCount < Int64(UInt32.max),
              TelegramPendingUploadItem.validRecord(file, identity: identity, attachmentID: Self.attachmentID(id)) else { return false }
        // Bound names and catalogue bytes before normalization or Set allocation.
        guard items.allSatisfy({ ($0.originalFile ?? $0.file).attachment.name.utf8.count <= TelegramUploadArchiveLimits.sourceNameBytes }),
              (try? TelegramUploadArchiveLimits.validateEntryNames(members.map(\.entryName))) != nil else { return false }

        var total: Int64 = 0
        var names = Set<String>()
        for (member, item) in zip(members, items) {
            let raw = item.originalFile ?? item.file
            guard member.itemID == item.id, item.sourceFacts != nil,
                  item.metadata?.voice == nil, item.metadata?.roundVideo == nil,
                  item.isValid(identity: identity, legacy: false),
                  raw.plaintextByteCount >= 0, raw.plaintextByteCount <= TelegramUploadArchiveLimits.sourceBytes - total,
                  Self.isSafeEntryName(member.entryName),
                  names.insert(member.entryName.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))).inserted else { return false }
            total += raw.plaintextByteCount
        }
        let itemIDs = items.map(\.id)
        let resources = items.flatMap { [$0.file] + ($0.originalFile.map { [$0] } ?? []) + ($0.videoCover.map { [$0.file] } ?? []) }
        let resourceIDs = resources.map(\.id)
        return Set(itemIDs).count == itemIDs.count && Set(resourceIDs).count == resourceIDs.count &&
            !itemIDs.contains(id) && !resourceIDs.contains(id) && id != file.id && !resourceIDs.contains(file.id)
    }

    private static func isSafeEntryName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains(":") &&
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

private struct ArchiveFieldKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireFields(_ decoder: any Decoder, expected: [String]) throws {
    let c = try decoder.container(keyedBy: ArchiveFieldKey.self)
    guard Set(c.allKeys.map(\.stringValue)) == Set(expected) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid archive fields"))
    }
}
