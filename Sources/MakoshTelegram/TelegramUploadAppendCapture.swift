import Foundation
import Postbox

/// One verified immutable candidate. A retry installs these exact records; it
/// never returns to picker URLs or repeats capture. Uninstalled captures do not
/// replace the previous restart-recoverable preparation.
struct TelegramUploadAppendCapture: Sendable {
    let snapshot: TelegramPendingUploadDraft
    let candidate: TelegramPendingUploadDraft
    let snapshotBytes: Data
    let candidateBytes: Data

    init(snapshot: TelegramPendingUploadDraft, candidate: TelegramPendingUploadDraft) throws {
        guard snapshot.isValid, candidate.isValid, [17, 18, 19].contains(snapshot.schemaVersion),
              snapshot.disposition == .prepared, candidate.disposition == .prepared,
              candidate.revision != snapshot.revision, candidate.items.count > snapshot.items.count,
              try telegramUploadAppendBytes(Array(candidate.items.prefix(snapshot.items.count))) == telegramUploadAppendBytes(snapshot.items) else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        switch (snapshot.captionPolicy, candidate.captionPolicy) {
        case let (.some(old), .some(new)):
            guard old.maximumUTF16Count == new.maximumUTF16Count,
                  Array(new.items.prefix(old.items.count)) == old.items else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
        case (.none, .none): break
        default: throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        let presentation = Self.presentation(snapshot: snapshot, items: candidate.items)
        if presentation == .archive {
            guard let archive = candidate.archive, archive.id != snapshot.archive?.id else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
        } else if candidate.archive != nil { throw TelegramPendingUploadPersistenceError.incompatibleData }
        let expected = try TelegramPendingUploadDraft(id: snapshot.id, revision: candidate.revision,
            accountID: snapshot.accountID, chatID: snapshot.chatID, title: snapshot.title,
            captionInput: snapshot.captionInput, captionAboveMedia: snapshot.captionAboveMedia, mediaSpoiler: snapshot.mediaSpoiler,
            originalDraft: snapshot.originalDraft, replyTarget: snapshot.replyTarget, items: candidate.items,
            isGrouped: snapshot.isGrouped && presentation.allowsGrouping(candidate.items), presentation: presentation,
            captionRules: snapshot.captionRules, mediaRules: snapshot.mediaRules, archive: candidate.archive,
            captionPolicy: candidate.captionPolicy)
        guard let encoded = encodePendingUpload(candidate), let base = encodePendingUpload(snapshot),
              try encoded == telegramUploadAppendBytes(expected) else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        self.snapshot = snapshot; self.candidate = candidate
        snapshotBytes = base; candidateBytes = encoded
    }

    static func presentation(snapshot: TelegramPendingUploadDraft, items: [TelegramPendingUploadItem]) -> TelegramUploadPresentation {
        snapshot.presentation == .media && !TelegramPendingUploadItem.allowsMedia(items, rules: snapshot.mediaRules) ? .file : snapshot.presentation
    }
}

func telegramUploadAppendBytes<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

/// The full predecessor comparison and pointer write execute in one native
/// transaction. A reused UUID never authorizes an older append or a false ACK.
nonisolated func telegramPendingUploadAppendWrite(transaction: Transaction, accountID: Int64,
    capture: TelegramUploadAppendCapture) -> Result<Void, TelegramPendingUploadPersistenceError> {
    guard capture.snapshot.accountID == accountID, capture.candidate.accountID == accountID else {
        return .failure(.incompatibleData)
    }
    switch telegramPendingUploadRead(transaction: transaction, accountID: accountID, chatID: capture.snapshot.chatID) {
    case let .failure(error): return .failure(error)
    case let .success(current):
        guard let current, let encoded = try? telegramUploadAppendBytes(current) else { return .failure(.conflict) }
        if encoded == capture.candidateBytes { return .success(()) }
        guard encoded == capture.snapshotBytes else { return .failure(.conflict) }
        return telegramPendingUploadWrite(transaction: transaction, accountID: accountID,
            draft: capture.candidate, expectedRevision: capture.snapshot.revision)
    }
}
