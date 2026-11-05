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
        let peerID = PeerId(chatID)
        let signal = account.postbox.transaction { transaction -> TelegramAIContextPage in
            telegramAIContextPage(transaction: transaction, peerID: peerID, range: range, now: Date())
        }
        return await withCheckedContinuation { continuation in
            _ = signal.start(next: { continuation.resume(returning: $0) })
        }
    }
}

func telegramAIContextPage(transaction: Transaction, peerID: PeerId, range: AIContextRange, now: Date) -> TelegramAIContextPage {
    let peer = transaction.getPeer(peerID)
    if peerID.namespace == Namespaces.Peer.SecretChat || peer is TelegramSecretChat {
        return TelegramAIContextPage(isSecret: true, isPrivate: true, peerID: peerID.toInt64(), messages: [], available: 0)
    }
    let channel = peer as? TelegramChannel, group = peer as? TelegramGroup
    let chatProtected = channel?.flags.contains(.copyProtectionEnabled) == true || group?.flags.contains(.copyProtectionEnabled) == true
    var read: [TelegramAIContextMessage] = []
    let start: Date? = {
        switch range {
        case .latest: return nil
        case .lastDays(let days): return now.addingTimeInterval(-TimeInterval(days) * 86_400)
        case .between(let from, _): return from
        }
    }()
    transaction.scanTopMessages(peerId: peerID, namespace: Namespaces.Message.Cloud, limit: TelegramEngineAIContextReader.limit) {
        message in
        let date = Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        if let start, date < start { return false }
        if case .latest(let count) = range, read.count >= count { return false }
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
        messages: TelegramAIContextProjection.select(read, range: range, now: now), available: read.count)
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
