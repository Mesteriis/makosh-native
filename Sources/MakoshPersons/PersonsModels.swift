import Foundation
import MakoshCore

/// Where persons come from and where address-book cards go. The channel kinds
/// (`mail`, `whatsapp`, `teams`) have no book of their own: they only collect
/// conversation partners and keep cursors.
public enum PersonBookKind: String, Codable, Sendable, CaseIterable {
    case telegram, carddav, googleContacts, macContacts, synthetic, mail, whatsapp, teams

    /// The `service` of identities this account produces.
    public var service: String {
        switch self {
        case .telegram: "telegram"
        case .carddav: "carddav"
        case .googleContacts: "google-contacts"
        case .macContacts: "macos-contacts"
        case .synthetic: "synthetic"
        case .mail: "mail"
        case .whatsapp: "whatsapp"
        case .teams: "teams"
        }
    }

    /// Whether this account has an address book Makosh can read and write.
    public var isBook: Bool {
        switch self {
        case .telegram, .carddav, .googleContacts, .macContacts, .synthetic: true
        case .mail, .whatsapp, .teams: false
        }
    }

    /// Whether this account has conversations whose partners become persons.
    public var hasConversations: Bool {
        switch self {
        case .telegram, .mail, .whatsapp, .teams: true
        case .carddav, .googleContacts, .macContacts, .synthetic: false
        }
    }
}

public enum PersonBookState: String, Codable, Sendable { case connected, needsSignIn, noAccess, unreachable, disabled }

/// One connected account as the Persons section sees it: its switches, its connection
/// state and its read cursor. Passwords live in the Keychain, never here.
public struct PersonBook: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: PersonBookKind
    public var name: String
    public var accountID: String
    /// Conversation partners of this account become persons.
    public var collectConversations: Bool
    /// The account's address book is read into persons.
    public var readBook: Bool
    /// Persons from this book are the user's address book: they get the flag.
    public var isAddressBookSource: Bool
    /// Flagged persons are written into this book.
    public var acceptsAddressBook: Bool
    public var state: PersonBookState
    public var lastError: PersonsFailure?
    public var cursor: Data?
    public var caldavServer: URL?
    public var caldavLogin: String?
    public var googleSubject: String?
    public var pausedUntil: Date?

    public init(
        id: UUID = UUID(), kind: PersonBookKind, name: String, accountID: String, collectConversations: Bool = true,
        readBook: Bool? = nil, isAddressBookSource: Bool = false, acceptsAddressBook: Bool? = nil, state: PersonBookState = .connected,
        lastError: PersonsFailure? = nil, cursor: Data? = nil, caldavServer: URL? = nil, caldavLogin: String? = nil,
        googleSubject: String? = nil, pausedUntil: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.accountID = accountID
        self.collectConversations = collectConversations
        self.readBook = kind.isBook && (readBook ?? true)
        self.isAddressBookSource = kind.isBook && isAddressBookSource
        self.acceptsAddressBook = kind.isBook && (acceptsAddressBook ?? true)
        self.state = state
        self.lastError = lastError
        self.cursor = cursor
        self.caldavServer = caldavServer
        self.caldavLogin = caldavLogin
        self.googleSubject = googleSubject
        self.pausedUntil = pausedUntil
    }

    public var source: ImportSource { ImportSource(service: kind.service, accountID: accountID) }
}

public enum PersonBookEntryState: String, Codable, Sendable {
    /// Makosh wrote this card and keeps it current.
    case managed
    /// A second card of a merged person in the same book; deleted only on request.
    case duplicate
    /// The card was removed outside Makosh, or the book was disconnected: no longer maintained.
    case notManaged
    /// Deleted by «Удалить везде» or replaced by a resend.
    case removed
}

/// The link between a person and its card in one book.
public struct PersonBookEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var personID: UUID
    public var bookID: UUID
    public var externalID: String
    public var etag: String?
    /// Fingerprint of the card last sent; `sentValues` lets a later read tell a removal from a never-sent value.
    public var fingerprint: String
    public var sentValues: [String: [String]]
    public var state: PersonBookEntryState
    /// The person this entry belonged to before a merge, so undo can give it back.
    public var mergedFromPersonID: UUID?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), personID: UUID, bookID: UUID, externalID: String, etag: String?, fingerprint: String,
        sentValues: [String: [String]] = [:], state: PersonBookEntryState, mergedFromPersonID: UUID? = nil, updatedAt: Date = Date()
    ) {
        self.id = id
        self.personID = personID
        self.bookID = bookID
        self.externalID = externalID
        self.etag = etag
        self.fingerprint = fingerprint
        self.sentValues = sentValues
        self.state = state
        self.mergedFromPersonID = mergedFromPersonID
        self.updatedAt = updatedAt
    }
}

public enum PersonAttemptKind: String, Codable, Sendable { case create, update, delete }

public enum PersonAttemptState: String, Codable, Sendable {
    case queued, sent, confirmed, rejected, unknown
    public var isOpen: Bool { self == .queued || self == .sent || self == .unknown }

    /// The only moves the store accepts.
    static func allows(_ from: PersonAttemptState, _ to: PersonAttemptState) -> Bool {
        switch (from, to) {
        case (.queued, .sent), (.sent, .confirmed), (.sent, .rejected), (.sent, .unknown), (.unknown, .confirmed), (.unknown, .rejected):
            true
        default: false
        }
    }
}

/// One write to an external book. An unknown outcome is settled by reading the book,
/// never by sending again.
public struct PersonAttempt: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var personID: UUID
    public var bookID: UUID
    public var entryID: UUID?
    public var kind: PersonAttemptKind
    public var state: PersonAttemptState
    /// Fingerprint of the card sent, not the card: no phones or addresses in the journal.
    public var fingerprint: String
    public var failure: PersonsFailure?
    public var createdAt: Date
    public var updatedAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(), personID: UUID, bookID: UUID, entryID: UUID?, kind: PersonAttemptKind, state: PersonAttemptState = .queued,
        fingerprint: String, failure: PersonsFailure? = nil, createdAt: Date = Date(), updatedAt: Date? = nil, resolvedAt: Date? = nil
    ) {
        self.id = id
        self.personID = personID
        self.bookID = bookID
        self.entryID = entryID
        self.kind = kind
        self.state = state
        self.fingerprint = fingerprint
        self.failure = failure
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.resolvedAt = resolvedAt
    }
}

/// Why something did not happen; never a response body, a URL or a token.
public enum PersonsFailure: Error, Codable, Equatable, Sendable {
    case invalidSchema, notOpen, notFound
    case storage(String?)
    case invalidInput(String)
    case rejected(code: Int, stage: String)
    case unknownOutcome(stage: String)
    case preconditionFailed
    case retryAfter(Int)
    case signInRequired, noAccess, unreachable
    /// Telegram needs a phone or a known peer to add a contact.
    case noPhoneOrPeer
    /// Telegram knows no account with this phone.
    case notInTelegram
}

public struct PersonsPreferences: Codable, Equatable, Sendable {
    public var pollIntervalSeconds = 600
    public var domainRuleEnabled = true
    public var companyRuleEnabled = true
    public var extraStopDomains: [String] = []
    public var extraRoleLocalParts: [String] = []
    public var expandedOrganizations: Set<UUID> = []
    public var filter = "all"
    public var showAddressBookOnly = false
    public var maxWritesPerPass = 50
    public init() {}
}

/// Where collection stopped for one source scope (a mail folder, a Telegram account).
public struct PersonCollectionCursor: Codable, Equatable, Sendable {
    public var source: ImportSource
    public var scope: String
    public var value: Data?
    public var updatedAt: Date
    public init(source: ImportSource, scope: String, value: Data?, updatedAt: Date = Date()) {
        self.source = source
        self.scope = scope
        self.value = value
        self.updatedAt = updatedAt
    }
}
