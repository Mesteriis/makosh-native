import Foundation
import CryptoKit
import MakoshCore
import Postbox
import TelegramCore
import SwiftSignalKit

/// Immutable projection on the account queue/main boundary; no credentials,
/// file references, cache paths or live engine objects enter PostgreSQL.
func telegramArchiveItem(_ entry: MakoshMessageJournalEntry, accountID: Int64) -> TelegramArchiveJournalItem {
    let identity = MessageArchiveIdentity(service: "telegram", accountID: String(accountID),
        conversationID: String(entry.id.peerId.toInt64()), messageID: "\(entry.id.namespace):\(entry.id.id)")
    let message = Message(stableId: 0, stableVersion: 0, id: entry.id, globallyUniqueId: nil,
        groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: entry.timestamp,
        flags: entry.flags, tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil,
        author: nil, text: entry.text, attributes: entry.attributes, media: entry.media,
        peers: SimpleDictionary(), associatedMessages: SimpleDictionary(), associatedMessageIds: [],
        associatedMedia: [:], associatedThreadInfo: nil, associatedStories: [:])
    let editedAt = entry.attributes.compactMap { ($0 as? EditedMessageAttribute)?.date }.max()
    let attachments = telegramAttachments(message).map { source in
        let a = source.attachment
        return MessageArchiveAttachment(id: a.id, kind: a.kind == .photo ? "photo" : a.kind == .file ? "file" : "unsupported",
                                        name: a.name, size: a.byteCount)
    }
    let content = MessageArchiveContent(date: Date(timeIntervalSince1970: TimeInterval(entry.timestamp)),
        editedAt: editedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }, text: entry.text,
        author: entry.authorId.map { "Telegram · \($0.toInt64())" } ?? "Telegram",
        authorID: entry.authorId.map { String($0.toInt64()) }, isOutgoing: !entry.flags.contains(.Incoming), attachments: attachments)
    let capturedAt = Date(timeIntervalSince1970: entry.capturedAt)
    var observations = [MessageArchiveObservation(id: entry.eventID, identity: identity,
        observedAt: capturedAt, source: .update, event: .message(content))]
    if entry.removed {
        observations.append(MessageArchiveObservation(id: telegramArchiveRemovalID(entry.eventID), identity: identity,
            observedAt: capturedAt, source: .update, event: .removedFromSource))
    }
    return TelegramArchiveJournalItem(sequence: entry.sequence, observations: observations)
}

func telegramArchiveRemovalID(_ eventID: UUID) -> UUID {
    var bytes = Array(SHA256.hash(data: Data((eventID.uuidString + ":removed-v1").utf8)).prefix(16))
    // RFC 9562 custom UUID version 8; domain-separated from snapshot event IDs.
    bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                       bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
}

// Build transaction bodies outside MainActor. The unannotated upstream signal
// API executes them on Postbox's queue; callbacks alone are delivered to main.
func telegramArchiveJournalRead(postbox: Postbox) -> Signal<Result<[MakoshMessageJournalEntry], TelegramArchiveReadError>, NoError> {
    postbox.transaction { transaction in
        do { return .success(try transaction.makoshArchiveJournal(limit: 100)) }
        catch { return .failure(.corrupt) }
    }
}

func telegramArchiveJournalAcknowledge(postbox: Postbox, sequences: [Int64]) -> Signal<Bool, NoError> {
    postbox.transaction { transaction in
        do { try transaction.acknowledgeMakoshArchiveJournal(sequences: sequences); return true }
        catch { return false }
    }
}

@MainActor final class TelegramEngineArchiveJournal: TelegramArchiveJournal {
    private let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }
    func read(receive: @escaping @MainActor (Result<[TelegramArchiveJournalItem], TelegramArchiveReadError>) -> Void) -> Disposable {
        let accountID = self.accountID
        return (telegramArchiveJournalRead(postbox: account.postbox) |> take(1) |> deliverOnMainQueue).start(next: { result in
            receive(result.map { entries in entries.map { telegramArchiveItem($0, accountID: accountID) } })
        })
    }
    func acknowledge(sequences: [Int64], receive: @escaping @MainActor (Bool) -> Void) -> Disposable {
        return (telegramArchiveJournalAcknowledge(postbox: account.postbox, sequences: sequences)
            |> take(1) |> deliverOnMainQueue).start(next: receive)
    }
}
