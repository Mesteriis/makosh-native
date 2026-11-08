import Foundation
import MakoshCore

/// One letter's evidence about an address: counted, never stored as text.
public struct MailEvidence: Equatable, Sendable {
    public var accountID: String
    public var address: String
    public var spam: Bool
    public init(accountID: String, address: String, spam: Bool) {
        self.accountID = accountID
        self.address = address
        self.spam = spam
    }
}

/// How a channel came to know a person: its address book, a conversation, or a letter.
public enum PersonSourceEvidence: Equatable, Sendable {
    case book
    case conversation
    case mail(MailEvidence)
}

/// What a channel hands the collector: a source-scoped person as it was seen.
public struct PersonSourceObservation: Equatable, Sendable {
    public var source: ImportSource
    public var person: ImportedPerson
    public var observedAt: Date
    public var evidence: PersonSourceEvidence
    /// The person this card is known to belong to (a card Makosh wrote, or one carrying its mark).
    public var personID: UUID?
    public init(source: ImportSource, person: ImportedPerson, observedAt: Date, evidence: PersonSourceEvidence, personID: UUID? = nil) {
        self.source = source
        self.person = person
        self.observedAt = observedAt
        self.evidence = evidence
        self.personID = personID
    }
}
