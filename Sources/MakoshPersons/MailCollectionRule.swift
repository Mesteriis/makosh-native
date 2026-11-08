import Foundation
import MakoshCore

public struct MailParticipant: Equatable, Sendable {
    public var address: String
    public var name: String
    public init(address: String, name: String) {
        self.address = address
        self.name = name
    }
}

public enum MailFolderRole: String, Sendable { case inbox, sent, junk, trash, other }

/// The facts about one letter that the rule needs; the letter itself never enters the section.
public struct MailLetterFacts: Equatable, Sendable {
    public var accountID: String
    public var folder: MailFolderRole
    public var from: MailParticipant?
    public var to: [MailParticipant]
    public var cc: [MailParticipant]
    public var bcc: [MailParticipant]
    public var ownAddresses: Set<String>
    public var hasListHeaders: Bool
    public var precedenceBulk: Bool
    public var autoSubmitted: Bool
    public var markedSpam: Bool
    public var observedAt: Date
    public init(
        accountID: String, folder: MailFolderRole, from: MailParticipant?, to: [MailParticipant], cc: [MailParticipant],
        bcc: [MailParticipant], ownAddresses: Set<String>, hasListHeaders: Bool, precedenceBulk: Bool, autoSubmitted: Bool,
        markedSpam: Bool, observedAt: Date
    ) {
        self.accountID = accountID
        self.folder = folder
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.ownAddresses = ownAddresses
        self.hasListHeaders = hasListHeaders
        self.precedenceBulk = precedenceBulk
        self.autoSubmitted = autoSubmitted
        self.markedSpam = markedSpam
        self.observedAt = observedAt
    }
}

/// Who in a letter is a real correspondent: the sender of a received letter, the
/// recipients of a sent one; never mailing lists, robots or the user's own addresses.
public enum MailCollectionRule {
    static let robotLocalParts: Set<String> = [
        "noreply", "no-reply", "donotreply", "do-not-reply", "mailer-daemon", "postmaster", "notifications", "notification", "bounce",
        "bounces", "no_reply",
    ]

    public static func isRobot(_ address: String) -> Bool {
        let normalized = PersonMatching.normalizedEmail(address)
        guard let at = normalized.firstIndex(of: "@") else { return false }
        let local = String(normalized[..<at])
        return robotLocalParts.contains(local) || local.hasPrefix("noreply") || local.hasPrefix("no-reply") || local.hasPrefix("bounce")
    }

    public static func observations(_ facts: MailLetterFacts) -> [PersonSourceObservation] {
        guard !facts.markedSpam, facts.folder != .junk, facts.folder != .trash else { return [] }
        guard !facts.hasListHeaders, !facts.precedenceBulk, !facts.autoSubmitted else { return [] }
        let candidates: [MailParticipant] =
            switch facts.folder {
            case .sent: facts.to + facts.cc + facts.bcc
            case .inbox, .other: facts.from.map { [$0] } ?? []
            case .junk, .trash: []
            }
        var seen = Set<String>()
        return candidates.compactMap { participant in
            let address = PersonMatching.normalizedEmail(participant.address)
            guard !address.isEmpty, !facts.ownAddresses.contains(address), !isRobot(address), seen.insert(address).inserted else {
                return nil
            }
            let name = participant.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return PersonSourceObservation(
                source: ImportSource(service: "mail", accountID: facts.accountID),
                person: ImportedPerson(externalID: address, displayName: name.isEmpty ? address : name, emails: [participant.address]),
                observedAt: facts.observedAt, evidence: .mail(MailEvidence(accountID: facts.accountID, address: address, spam: false)))
        }
    }

    /// Senders of letters the user or the provider marked as spam; the collector counts them.
    public static func spamEvidence(_ facts: MailLetterFacts) -> [MailEvidence] {
        guard facts.markedSpam || facts.folder == .junk, let from = facts.from else { return [] }
        let address = PersonMatching.normalizedEmail(from.address)
        guard !address.isEmpty, !facts.ownAddresses.contains(address) else { return [] }
        return [MailEvidence(accountID: facts.accountID, address: address, spam: true)]
    }
}
