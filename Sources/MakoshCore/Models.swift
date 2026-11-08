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
        self.service = service
        self.accountID = accountID
        self.externalID = externalID
    }
}

public struct SourceStamp: Codable, Hashable, Sendable {
    public var identity: ServiceIdentity
    public var fetchedAt: Date
    public init(identity: ServiceIdentity, fetchedAt: Date = Date()) {
        self.identity = identity
        self.fetchedAt = fetchedAt
    }
}

/// How a value was learnt: seen at a source, proposed by the AI (not yet current), or confirmed by the user.
public enum ObservationStatus: String, Codable, Sendable { case observed, proposed, confirmed }

public struct Observation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var field: String
    public var value: String
    public var source: SourceStamp
    public var status: ObservationStatus
    public init(id: UUID = UUID(), field: String, value: String, source: SourceStamp, status: ObservationStatus = .observed) {
        self.id = id
        self.field = field
        self.value = value
        self.source = source
        self.status = status
    }
    private enum CodingKeys: String, CodingKey { case id, field, value, source, status }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        field = try c.decode(String.self, forKey: .field)
        value = try c.decode(String.self, forKey: .value)
        source = try c.decode(SourceStamp.self, forKey: .source)
        // Rows written before statuses existed were all observed at a source.
        status = try c.decodeIfPresent(ObservationStatus.self, forKey: .status) ?? .observed
    }
}

public enum PersonKind: String, Codable, Sendable { case person, organization }

/// Who set the address-book flag: the user, or a book account marked as the user's address book.
public enum AddressBookOrigin: Codable, Equatable, Sendable {
    case user
    case sourceAccount(ImportSource)
}

public enum FormerReason: Codable, Equatable, Sendable {
    case removedByUser
    case removedInBook(ImportSource)
    case replacedByMerge
}

/// A value that used to be current. Nothing is erased from a person: it moves here.
public struct FormerValue: Codable, Equatable, Sendable {
    public var field: String
    public var value: String
    public var since: Date
    public var reason: FormerReason
    public init(field: String, value: String, since: Date = Date(), reason: FormerReason) {
        self.field = field
        self.value = value
        self.since = since
        self.reason = reason
    }
}

/// One list entry the user typed or kept by hand; sources never remove it.
public struct ManualValue: Codable, Hashable, Sendable {
    public var field: String
    public var value: String
    public init(field: String, value: String) {
        self.field = field
        self.value = value
    }
}

/// The person's list fields, named once for provenance rules and the value index.
public enum PersonListField: String, CaseIterable, Codable, Sendable { case phones, emails, usernames, tags }

/// What a list shows: kind, name, first contact values and the flag, without observations or notes.
public struct PersonSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: PersonKind
    public var displayName: String
    public var organization: String
    public var jobTitle: String
    public var firstEmail: String?
    public var firstPhone: String?
    public var addressBook: Bool
    public var isActive: Bool
    public var revision: Int
    public init(
        id: UUID, kind: PersonKind, displayName: String, organization: String, jobTitle: String, firstEmail: String?,
        firstPhone: String?, addressBook: Bool, isActive: Bool, revision: Int
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.organization = organization
        self.jobTitle = jobTitle
        self.firstEmail = firstEmail
        self.firstPhone = firstPhone
        self.addressBook = addressBook
        self.isActive = isActive
        self.revision = revision
    }
}

public struct PersonNote: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var source: SourceStamp
    public init(id: UUID = UUID(), text: String, source: SourceStamp) {
        self.id = id
        self.text = text
        self.source = source
    }
}

public struct PersonEvent: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var kind: String
    public var detail: String
    public init(id: UUID = UUID(), date: Date = Date(), kind: String, detail: String) {
        self.id = id
        self.date = date
        self.kind = kind
        self.detail = detail
    }
}

public struct PersonDraft: Equatable, Sendable {
    public var kind: PersonKind
    public var displayName: String
    public var givenName: String
    public var familyName: String
    public var middleName: String
    public var organization: String
    public var jobTitle: String
    public var phones: [String]
    public var emails: [String]
    public var usernames: [String]
    public var tags: [String]
    public init(
        kind: PersonKind = .person, displayName: String = "", givenName: String = "", familyName: String = "", middleName: String = "",
        organization: String = "", jobTitle: String = "",
        phones: [String] = [], emails: [String] = [], usernames: [String] = [], tags: [String] = []
    ) {
        self.kind = kind
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.middleName = middleName
        self.organization = organization
        self.jobTitle = jobTitle
        self.phones = phones
        self.emails = emails
        self.usernames = usernames
        self.tags = tags
    }
}

public struct Person: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: PersonKind = .person
    public var displayName: String
    public var givenName: String = ""
    public var familyName: String = ""
    public var middleName: String = ""
    public var organization: String
    public var jobTitle: String
    public var phones: [String]
    public var emails: [String]
    public var usernames: [String] = []
    public var tags: [String]
    public var identities: [ServiceIdentity]
    public var observations: [Observation]
    public var notes: [PersonNote]
    public var events: [PersonEvent]
    /// Scalar fields the user set by hand; sources no longer write them.
    public var manualFields: Set<String>
    /// List entries the user set by hand; sources add beside them and never remove them.
    public var manualValues: Set<ManualValue> = []
    public var former: [FormerValue] = []
    public var addressBook: Bool = false
    public var addressBookOrigin: AddressBookOrigin?
    public var deletedAt: Date?
    public var hiddenAsSpam: Bool = false
    public var revision: Int
    public var aiAccess: AIContactAccess = .inherit
    public var draft: PersonDraft {
        PersonDraft(
            kind: kind, displayName: displayName, givenName: givenName, familyName: familyName, middleName: middleName,
            organization: organization, jobTitle: jobTitle, phones: phones, emails: emails, usernames: usernames, tags: tags)
    }
    public var isActive: Bool { deletedAt == nil && !hiddenAsSpam }
    /// The structured name when set, else the display name split at its first space.
    public var nameParts: (given: String, family: String) {
        if !givenName.isEmpty || !familyName.isEmpty { return (givenName, familyName) }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(where: \.isWhitespace) else { return (trimmed, "") }
        return (String(trimmed[..<space]), trimmed[space...].trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public var summary: PersonSummary {
        PersonSummary(
            id: id, kind: kind, displayName: displayName, organization: organization, jobTitle: jobTitle, firstEmail: emails.first,
            firstPhone: phones.first, addressBook: addressBook, isActive: isActive, revision: revision)
    }
    public func values(_ field: PersonListField) -> [String] {
        switch field {
        case .phones: phones
        case .emails: emails
        case .usernames: usernames
        case .tags: tags
        }
    }
    public mutating func setValues(_ values: [String], for field: PersonListField) {
        switch field {
        case .phones: phones = values
        case .emails: emails = values
        case .usernames: usernames = values
        case .tags: tags = values
        }
    }
    public init(
        id: UUID = UUID(), displayName: String, organization: String = "", jobTitle: String = "",
        phones: [String] = [], emails: [String] = [], tags: [String] = [],
        identities: [ServiceIdentity] = [], observations: [Observation] = [],
        notes: [PersonNote] = [], events: [PersonEvent] = [],
        manualFields: Set<String> = [], revision: Int = 1
    ) {
        self.id = id
        self.displayName = displayName
        self.organization = organization
        self.jobTitle = jobTitle
        self.phones = phones
        self.emails = emails
        self.tags = tags
        self.identities = identities
        self.observations = observations
        self.notes = notes
        self.events = events
        self.manualFields = manualFields
        self.revision = revision
    }
    private enum CodingKeys: String, CodingKey {
        case id, kind, displayName, givenName, familyName, middleName, organization, jobTitle, phones, emails, usernames, tags, identities,
            observations, notes, events, manualFields, manualValues, former, addressBook, addressBookOrigin, deletedAt, hiddenAsSpam,
            revision, aiAccess
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // Rows written by store versions 1 and 2 carry none of the version-3 fields.
        kind = try c.decodeIfPresent(PersonKind.self, forKey: .kind) ?? .person
        displayName = try c.decode(String.self, forKey: .displayName)
        givenName = try c.decodeIfPresent(String.self, forKey: .givenName) ?? ""
        familyName = try c.decodeIfPresent(String.self, forKey: .familyName) ?? ""
        middleName = try c.decodeIfPresent(String.self, forKey: .middleName) ?? ""
        organization = try c.decode(String.self, forKey: .organization)
        jobTitle = try c.decode(String.self, forKey: .jobTitle)
        phones = try c.decode([String].self, forKey: .phones)
        emails = try c.decode([String].self, forKey: .emails)
        usernames = try c.decodeIfPresent([String].self, forKey: .usernames) ?? []
        tags = try c.decode([String].self, forKey: .tags)
        identities = try c.decode([ServiceIdentity].self, forKey: .identities)
        observations = try c.decode([Observation].self, forKey: .observations)
        notes = try c.decode([PersonNote].self, forKey: .notes)
        events = try c.decode([PersonEvent].self, forKey: .events)
        manualFields = try c.decode(Set<String>.self, forKey: .manualFields)
        manualValues = try c.decodeIfPresent(Set<ManualValue>.self, forKey: .manualValues) ?? []
        former = try c.decodeIfPresent([FormerValue].self, forKey: .former) ?? []
        addressBook = try c.decodeIfPresent(Bool.self, forKey: .addressBook) ?? false
        addressBookOrigin = try c.decodeIfPresent(AddressBookOrigin.self, forKey: .addressBookOrigin)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        hiddenAsSpam = try c.decodeIfPresent(Bool.self, forKey: .hiddenAsSpam) ?? false
        revision = try c.decode(Int.self, forKey: .revision)
        // Rows written before AI access existed default to inherit.
        aiAccess = try c.decodeIfPresent(AIContactAccess.self, forKey: .aiAccess) ?? .inherit
    }
}

public struct ImportSource: Codable, Equatable, Sendable {
    public var service: String
    public var accountID: String
    public init(service: String, accountID: String) {
        self.service = service
        self.accountID = accountID
    }
}

public struct ImportedPerson: Codable, Equatable, Sendable {
    public var externalID: String
    public var displayName: String
    public var givenName: String?
    public var familyName: String?
    public var middleName: String?
    public var organization: String?
    public var jobTitle: String?
    public var phones: [String]
    public var emails: [String]
    public var usernames: [String]
    public var tags: [String]
    public var notes: [String]
    public init(
        externalID: String, displayName: String, givenName: String? = nil, familyName: String? = nil, middleName: String? = nil,
        organization: String? = nil, jobTitle: String? = nil,
        phones: [String] = [], emails: [String] = [], usernames: [String] = [], tags: [String] = [], notes: [String] = []
    ) {
        self.externalID = externalID
        self.displayName = displayName
        self.givenName = givenName
        self.familyName = familyName
        self.middleName = middleName
        self.organization = organization
        self.jobTitle = jobTitle
        self.phones = phones
        self.emails = emails
        self.usernames = usernames
        self.tags = tags
        self.notes = notes
    }
    private enum CodingKeys: String, CodingKey {
        case externalID, displayName, givenName, familyName, middleName, organization, jobTitle, phones, emails, usernames, tags, notes
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        externalID = try c.decode(String.self, forKey: .externalID)
        displayName = try c.decode(String.self, forKey: .displayName)
        givenName = try c.decodeIfPresent(String.self, forKey: .givenName)
        familyName = try c.decodeIfPresent(String.self, forKey: .familyName)
        middleName = try c.decodeIfPresent(String.self, forKey: .middleName)
        organization = try c.decodeIfPresent(String.self, forKey: .organization)
        jobTitle = try c.decodeIfPresent(String.self, forKey: .jobTitle)
        phones = try c.decodeIfPresent([String].self, forKey: .phones) ?? []
        emails = try c.decodeIfPresent([String].self, forKey: .emails) ?? []
        usernames = try c.decodeIfPresent([String].self, forKey: .usernames) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

public struct ImportDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var source: ImportSource
    public var fetchedAt: Date
    public var contacts: [ImportedPerson]
    public init(schemaVersion: Int = 1, source: ImportSource, fetchedAt: Date = Date(), contacts: [ImportedPerson]) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.fetchedAt = fetchedAt
        self.contacts = contacts
    }
    public static func decode(_ data: Data) throws -> ImportDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ImportDocument.self, from: data)
    }
}

public struct ImportResult: Equatable, Sendable {
    public var created: Int
    public var updated: Int
    public init(created: Int, updated: Int) {
        self.created = created
        self.updated = updated
    }
}

public struct DuplicateCandidate: Identifiable, Equatable, Sendable {
    public var firstID: UUID
    public var secondID: UUID
    public var reasons: [String]
    public var id: String { firstID.uuidString + secondID.uuidString }
    public init(firstID: UUID, secondID: UUID, reasons: [String]) {
        self.firstID = firstID
        self.secondID = secondID
        self.reasons = reasons
    }
}

public struct MergeRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var survivorBefore: Person
    public var removedBefore: Person
    public var expectedRevision: Int
    public var mergedAt: Date
    public var undoneAt: Date?
    public init(
        id: UUID = UUID(), survivorBefore: Person, removedBefore: Person,
        expectedRevision: Int, mergedAt: Date = Date(), undoneAt: Date? = nil
    ) {
        self.id = id
        self.survivorBefore = survivorBefore
        self.removedBefore = removedBefore
        self.expectedRevision = expectedRevision
        self.mergedAt = mergedAt
        self.undoneAt = undoneAt
    }
}

public enum StoreError: LocalizedError {
    case invalid(String), missingPerson, undoConflict, database(String), unsupportedSchema(Int)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .missingPerson: return "Контакт больше не существует. Обновите список."
        case .undoConflict: return "Отмена остановлена: после объединения данные изменились. Последующие изменения сохранены."
        case .database: return "Не удалось выполнить действие в PostgreSQL. Проверьте доступность базы данных и повторите попытку."
        case .unsupportedSchema(let version): return "Версия хранилища \(version) не поддерживается."
        }
    }
}
