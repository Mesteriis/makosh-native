import Foundation

public struct ServiceIdentity: Codable, Hashable, Identifiable, Sendable {
    public var service: String
    public var accountID: String
    public var externalID: String
    // Opaque source identifiers use exact UTF-8 bytes, including normalization.
    // Base64's alphabet excludes '.', so component boundaries remain unambiguous.
    public var id: String { [service, accountID, externalID].map { Data($0.utf8).base64EncodedString() }.joined(separator: ".") }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.service.utf8.elementsEqual(rhs.service.utf8)
            && lhs.accountID.utf8.elementsEqual(rhs.accountID.utf8)
            && lhs.externalID.utf8.elementsEqual(rhs.externalID.utf8)
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    public init(service: String, accountID: String, externalID: String) {
        self.service = service; self.accountID = accountID; self.externalID = externalID
    }
}

public struct SourceStamp: Codable, Hashable, Sendable {
    public var identity: ServiceIdentity
    public var fetchedAt: Date
    public init(identity: ServiceIdentity, fetchedAt: Date = Date()) {
        self.identity = identity; self.fetchedAt = fetchedAt
    }
}

public struct Observation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var field: String
    public var value: String
    public var source: SourceStamp
    public init(id: UUID = UUID(), field: String, value: String, source: SourceStamp) {
        self.id = id; self.field = field; self.value = value; self.source = source
    }
}

public struct ContactNote: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var source: SourceStamp
    public init(id: UUID = UUID(), text: String, source: SourceStamp) {
        self.id = id; self.text = text; self.source = source
    }
}

public struct ContactEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: String
    public var detail: String
    public init(id: UUID = UUID(), date: Date = Date(), kind: String, detail: String) {
        self.id = id; self.date = date; self.kind = kind; self.detail = detail
    }
}

public struct ContactDraft: Equatable, Sendable {
    public var displayName: String
    public var organization: String
    public var jobTitle: String
    public var phones: [String]
    public var emails: [String]
    public var tags: [String]
    public init(displayName: String = "", organization: String = "", jobTitle: String = "",
                phones: [String] = [], emails: [String] = [], tags: [String] = []) {
        self.displayName = displayName; self.organization = organization; self.jobTitle = jobTitle
        self.phones = phones; self.emails = emails; self.tags = tags
    }
}

public struct Contact: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var displayName: String
    public var organization: String
    public var jobTitle: String
    public var phones: [String]
    public var emails: [String]
    public var tags: [String]
    public var identities: [ServiceIdentity]
    public var observations: [Observation]
    public var notes: [ContactNote]
    public var events: [ContactEvent]
    public var manualFields: Set<String>
    public var revision: Int
    public var draft: ContactDraft {
        ContactDraft(displayName: displayName, organization: organization, jobTitle: jobTitle,
                     phones: phones, emails: emails, tags: tags)
    }
    public init(id: UUID = UUID(), displayName: String, organization: String = "", jobTitle: String = "",
                phones: [String] = [], emails: [String] = [], tags: [String] = [],
                identities: [ServiceIdentity] = [], observations: [Observation] = [],
                notes: [ContactNote] = [], events: [ContactEvent] = [],
                manualFields: Set<String> = [], revision: Int = 1) {
        self.id = id; self.displayName = displayName; self.organization = organization; self.jobTitle = jobTitle
        self.phones = phones; self.emails = emails; self.tags = tags; self.identities = identities
        self.observations = observations; self.notes = notes; self.events = events
        self.manualFields = manualFields; self.revision = revision
    }
}

public struct ImportSource: Codable, Equatable, Sendable {
    public var service: String
    public var accountID: String
    public init(service: String, accountID: String) { self.service = service; self.accountID = accountID }
}

public struct ImportedContact: Codable, Equatable, Sendable {
    public var externalID: String
    public var displayName: String
    public var organization: String?
    public var jobTitle: String?
    public var phones: [String]
    public var emails: [String]
    public var tags: [String]
    public var notes: [String]
    public init(externalID: String, displayName: String, organization: String? = nil, jobTitle: String? = nil,
                phones: [String] = [], emails: [String] = [], tags: [String] = [], notes: [String] = []) {
        self.externalID = externalID; self.displayName = displayName; self.organization = organization
        self.jobTitle = jobTitle; self.phones = phones; self.emails = emails; self.tags = tags; self.notes = notes
    }
    private enum CodingKeys: String, CodingKey {
        case externalID, displayName, organization, jobTitle, phones, emails, tags, notes
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        externalID = try c.decode(String.self, forKey: .externalID)
        displayName = try c.decode(String.self, forKey: .displayName)
        organization = try c.decodeIfPresent(String.self, forKey: .organization)
        jobTitle = try c.decodeIfPresent(String.self, forKey: .jobTitle)
        phones = try c.decodeIfPresent([String].self, forKey: .phones) ?? []
        emails = try c.decodeIfPresent([String].self, forKey: .emails) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

public struct ImportDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var source: ImportSource
    public var fetchedAt: Date
    public var contacts: [ImportedContact]
    public init(schemaVersion: Int = 1, source: ImportSource, fetchedAt: Date = Date(), contacts: [ImportedContact]) {
        self.schemaVersion = schemaVersion; self.source = source; self.fetchedAt = fetchedAt; self.contacts = contacts
    }
    public static func decode(_ data: Data) throws -> ImportDocument {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ImportDocument.self, from: data)
    }
}

public struct ImportResult: Equatable, Sendable {
    public var created: Int
    public var updated: Int
    public init(created: Int, updated: Int) { self.created = created; self.updated = updated }
}

public struct DuplicateCandidate: Identifiable, Equatable, Sendable {
    public var firstID: UUID
    public var secondID: UUID
    public var reasons: [String]
    public var id: String { firstID.uuidString + secondID.uuidString }
    public init(firstID: UUID, secondID: UUID, reasons: [String]) {
        self.firstID = firstID; self.secondID = secondID; self.reasons = reasons
    }
}

public struct MergeRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var survivorBefore: Contact
    public var removedBefore: Contact
    public var expectedRevision: Int
    public var mergedAt: Date
    public var undoneAt: Date?
    public init(id: UUID = UUID(), survivorBefore: Contact, removedBefore: Contact,
                expectedRevision: Int, mergedAt: Date = Date(), undoneAt: Date? = nil) {
        self.id = id; self.survivorBefore = survivorBefore; self.removedBefore = removedBefore
        self.expectedRevision = expectedRevision; self.mergedAt = mergedAt; self.undoneAt = undoneAt
    }
}

public enum StoreError: LocalizedError {
    case invalid(String), missingContact, undoConflict, database(String), unsupportedSchema(Int)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .missingContact: return "Контакт больше не существует. Обновите список."
        case .undoConflict: return "Отмена остановлена: после объединения данные изменились. Последующие изменения сохранены."
        case .database: return "Не удалось выполнить действие в PostgreSQL. Проверьте доступность базы данных и повторите попытку."
        case .unsupportedSchema(let version): return "Версия хранилища \(version) не поддерживается."
        }
    }
}
