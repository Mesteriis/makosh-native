import Foundation
import MakoshCore
import Postbox
import SwiftSignalKit
import TelegramCore

/// Reads a chat's locally stored history for an attached AI context card.
@MainActor public protocol TelegramAIContextReading: AnyObject {
    var accountID: Int64 { get }
    func page(chatID: Int64, range: AIContextRange) async throws -> TelegramAIContextPage
}

/// One Postbox read transaction on the postbox queue; only the finished page
/// reaches the caller. At most `limit` newest messages are read per request.
@MainActor final class TelegramEngineAIContextReader: TelegramAIContextReading {
    nonisolated static let limit = 5_000
    private let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }

    func page(chatID: Int64, range: AIContextRange) async throws -> TelegramAIContextPage {
        try await telegramAIContextFirst(Self.read(postbox: account.postbox, peerID: PeerId(chatID), range: range))
    }

    /// Built outside the main actor so the transaction closure never inherits its isolation.
    nonisolated private static func read(postbox: Postbox, peerID: PeerId, range: AIContextRange) -> Signal<TelegramAIContextPage, NoError>
    {
        postbox.transaction { transaction -> TelegramAIContextPage in
            telegramAIContextPage(transaction: transaction, peerID: peerID, range: range, now: Date())
        }
    }
}

enum TelegramAIContextReadError: Error { case ended }

/// Resumes a continuation exactly once, whichever signal event comes first.
private final class TelegramAIContextOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    func set(_ value: CheckedContinuation<T, Error>) { lock.withLock { continuation = value } }
    func resume(_ result: Result<T, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

/// The first value of a signal that may deliver on any queue.
@MainActor func telegramAIContextFirst<T: Sendable>(_ signal: Signal<T, NoError>) async throws -> T {
    let once = TelegramAIContextOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        once.set(continuation)
        telegramAIContextSubscribe(signal, once)
    }
}

/// The subscriber closures are formed here, outside any actor: formed on the
/// main actor they would trap when Postbox calls them on its own queue.
nonisolated private func telegramAIContextSubscribe<T: Sendable>(_ signal: Signal<T, NoError>, _ once: TelegramAIContextOnce<T>) {
    _ = signal.start(next: { once.resume(.success($0)) }, completed: { once.resume(.failure(TelegramAIContextReadError.ended)) })
}

func telegramAIContextPage(transaction: Transaction, peerID: PeerId, range: AIContextRange, now: Date) -> TelegramAIContextPage {
    let peer = transaction.getPeer(peerID)
    if peerID.namespace == Namespaces.Peer.SecretChat || peer is TelegramSecretChat {
        return TelegramAIContextPage(isSecret: true, isPrivate: true, peerID: peerID.toInt64(), messages: [], available: 0)
    }
    let channel = peer as? TelegramChannel, group = peer as? TelegramGroup
    let chatProtected = channel?.flags.contains(.copyProtectionEnabled) == true || group?.flags.contains(.copyProtectionEnabled) == true
    var read: [TelegramAIContextMessage] = []
    var scanned = 0, reachedStart = false
    let end: Date? = { if case .between(_, let to) = range { return to } else { return nil } }()
    let start: Date? = {
        switch range {
        case .latest: return nil
        case .lastDays(let days): return now.addingTimeInterval(-TimeInterval(days) * 86_400)
        case .between(let from, _): return from
        }
    }()
    transaction.scanTopMessages(peerId: peerID, namespace: Namespaces.Message.Cloud, limit: TelegramEngineAIContextReader.limit) {
        message in
        scanned += 1
        let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        if let start, date < start {
            reachedStart = true
            return false
        }
        if case .latest(let count) = range, read.count >= count {
            reachedStart = true
            return false
        }
        // Newer than the period: skipped, never offered.
        if let end, date > end { return true }
        guard !message.flags.contains(.Unsent), !message.flags.contains(.Failed) else { return true }
        let author = message.author ?? message.peers[message.id.peerId]
        read.append(
            TelegramAIContextMessage(
                authorID: author?.id.toInt64() ?? 0, authorName: telegramAIContextName(author),
                isOutgoing: !message.flags.contains(.Incoming), date: date, text: message.text,
                isProtected: chatProtected || message.flags.contains(.CopyProtected) || message.containsSecretMedia))
        return true
    }
    return TelegramAIContextPage(
        isSecret: false, isPrivate: peer is TelegramUser, peerID: peerID.toInt64(),
        messages: TelegramAIContextProjection.select(read, range: range, now: now), available: read.count,
        truncated: !reachedStart && scanned >= TelegramEngineAIContextReader.limit)
}

private func telegramAIContextName(_ peer: Peer?) -> String {
    switch peer {
    case let user as TelegramUser:
        let name = [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? (user.username ?? "Пользователь") : name
    case let channel as TelegramChannel: return channel.title
    case let group as TelegramGroup: return group.title
    default: return "Участник"
    }
}
