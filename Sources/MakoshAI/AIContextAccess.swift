import Foundation
import MakoshCore

/// A message read for a card, before the access rules.
public struct AIContextCandidate: Sendable, Equatable {
    public let author: ServiceIdentity?
    public let line: AIContextLine
    public let isProtected: Bool
    public init(author: ServiceIdentity?, line: AIContextLine, isProtected: Bool) {
        self.author = author
        self.line = line
        self.isProtected = isProtected
    }
}

/// What may leave for an explicitly attached card. The chat's "available to
/// AI" flag does not apply here; a forbidden contact always does.
public enum AIContextAccess {
    /// `privatePeer` is the other person of a one-to-one chat. Such a chat
    /// with a forbidden contact is not sent at all, the user's own messages
    /// included; elsewhere a forbidden author's messages are dropped and counted.
    public static func apply(
        _ candidates: [AIContextCandidate], privatePeer: ServiceIdentity?, snapshot: AIAccessSnapshot
    ) throws -> (lines: [AIContextLine], hiddenForbidden: Int, hiddenProtected: Int) {
        if let privatePeer, snapshot.contactAccess[privatePeer] == .forbidden {
            throw AIFailure.contextUnavailable("Контакт закрыт для ИИ в досье — этот чат нельзя прикрепить.")
        }
        var lines: [AIContextLine] = []
        var forbidden = 0, protected = 0
        for candidate in candidates {
            if candidate.isProtected {
                protected += 1
            } else if !candidate.line.isOutgoing, let author = candidate.author, snapshot.contactAccess[author] == .forbidden {
                forbidden += 1
            } else {
                lines.append(candidate.line)
            }
        }
        return (lines, forbidden, protected)
    }

    /// A contact's dossier, or a letter from a forbidden sender, is never attached.
    public static func requireOpen(_ identity: ServiceIdentity?, snapshot: AIAccessSnapshot, what: String) throws {
        guard let identity, snapshot.contactAccess[identity] == .forbidden else { return }
        throw AIFailure.contextUnavailable("Контакт закрыт для ИИ в досье — \(what) нельзя прикрепить.")
    }
}
