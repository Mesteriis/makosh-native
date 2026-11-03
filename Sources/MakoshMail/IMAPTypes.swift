// Derived from MMail, copyright (c) 2026 moerdowo, MIT.
// Pinned source and retained notice: Dependencies/Mail.lock.json, Dependencies/Mail/MMail.MIT.notice.
// Makosh adaptations are recorded in docs/mail-migration.md.
import Foundation
import NIO
import NIOCore
import NIOPosix
import NIOIMAP
import NIOIMAPCore

enum MailError: LocalizedError {
    case notConnected
    case connectFailed(String)
    case commandFailed(String)
    case noResult

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        case .connectFailed(let m): return "Connection failed: \(m)"
        case .commandFailed(let m): return "Server rejected the command: \(m)"
        case .noResult: return "No response from server."
        }
    }
}

struct IMAPMessage: Sendable {
    var uid: UInt32
    var subject: String
    var fromName: String
    var fromEmail: String
    var toName: String
    var toEmail: String
    var ccEmail: String
    var bccEmail: String
    var date: Date
    var seen: Bool
    var flagged: Bool
    var messageID: String
    var inReplyTo: String
    var keywords: [String]
}

// NIO-free flag kind so the app layer doesn't import NIOIMAPCore.
enum MailFlagKind: Sendable { case seen, flagged, deleted }

/// Linearizes cancellation against the final command write on NIO's event loop.
final class MailCommandDispatch: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    func dispatch<Value>(_ write: () throws -> Value) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        return try write()
    }
}

// NIO-free incremental-sync results.
struct IMAPFlagState: Sendable {
    var seen: Bool
    var flagged: Bool
    var keywords: [String]
}

struct IMAPFolderSync: Sendable {
    var newMessages: [IMAPMessage]  // UID greater than the highest we had
    var flags: [UInt32: IMAPFlagState]  // current flags for the already-loaded range
}

// NIO-free advanced-search criteria. The app builds this; IMAPService turns it
// into a server SearchKey so the app layer stays free of NIOIMAPCore.
struct MailSearchCriteria: Sendable {
    var text = ""
    var from = ""
    var to = ""
    var subject = ""
    var since: Date?
    var before: Date?
    var unseenOnly = false
    var flaggedOnly = false

    var isEmpty: Bool {
        text.isEmpty && from.isEmpty && to.isEmpty && subject.isEmpty
            && since == nil && before == nil && !unseenOnly && !flaggedOnly
    }
}

enum MailboxKind: String, Codable, Sendable { case inbox, sent, drafts, trash, junk, archive, other }

struct IMAPMailbox: Sendable {
    let name: String  // server mailbox path (used for SELECT/MOVE)
    let displayName: String
    let kind: MailboxKind
    let selectable: Bool
}
