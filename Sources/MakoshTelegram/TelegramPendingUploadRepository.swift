import Foundation
import CryptoKit
import Postbox
import SwiftSignalKit

internal enum TelegramPendingUploadPersistenceError: Error, LocalizedError, Equatable {
    case unavailable, incompatibleData, conflict
    var errorDescription: String? {
        switch self {
        case .unavailable: "Не удалось сохранить или открыть подготовленное вложение."
        case .incompatibleData: "Подготовленное вложение имеет несовместимый формат. Данные не изменены."
        case .conflict: "Подготовленное вложение изменилось. Данные не перезаписаны."
        }
    }
}
@MainActor internal protocol TelegramPendingUploadRepository: AnyObject {
    var accountID: Int64 { get }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable
    func save(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID?, completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void)
    func loadArchiveIntent(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveIntent?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable
    func retainArchiveIntent(_ intent: TelegramPendingUploadArchiveIntent, chatID: Int64, admission: TelegramPendingUploadArchiveAdmission,
                             completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void)
    func loadArchiveCapture(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveCapture?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable
    func retainArchiveCapture(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID,
                              admission: TelegramPendingUploadArchiveAdmission,
                              completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void)
    func installArchive(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID,
                        admission: TelegramPendingUploadArchiveAdmission,
                        completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void)
}
extension TelegramPendingUploadRepository {
    func loadArchiveIntent(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveIntent?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        completion(.failure(.incompatibleData)); return EmptyDisposable
    }
    func retainArchiveIntent(_ intent: TelegramPendingUploadArchiveIntent, chatID: Int64, admission: TelegramPendingUploadArchiveAdmission,
                             completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        completion(.failure(.incompatibleData))
    }
    func loadArchiveCapture(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveCapture?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        completion(.failure(.incompatibleData)); return EmptyDisposable
    }
    func retainArchiveCapture(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID,
                              admission: TelegramPendingUploadArchiveAdmission,
                              completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        completion(.failure(.incompatibleData))
    }
    func installArchive(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID,
                        admission: TelegramPendingUploadArchiveAdmission,
                        completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        // An older adapter must not turn a guarded install into an ordinary save.
        completion(.failure(.incompatibleData))
    }
}
private let pendingUploadMarker = Data("Makosh.PendingUpload.JSON.v1\n".utf8)
// A long owned namespace plus fixed-width account/chat fields, never a native
// persistentChatInterfaceData key. Exposed internally for corruption fixtures.
nonisolated func telegramPendingUploadKey(accountID: Int64, chatID: Int64) -> ValueBoxKey {
    let namespace = Data("Makosh.PendingUpload.Preference.v1\0".utf8)
    let key = ValueBoxKey(length: namespace.count + 16)
    key.setData(0, value: namespace)
    key.setInt64(namespace.count, value: accountID)
    key.setInt64(namespace.count + 8, value: chatID)
    return key
}
// Separate from the pending pointer so schemas1–16 remain byte-compatible.
// The receipt binds one predecessor revision to the exact installed candidate.
nonisolated func telegramPendingUploadArchiveInstallKey(accountID: Int64, chatID: Int64) -> ValueBoxKey {
    let namespace = Data("Makosh.PendingUpload.ArchiveInstall.Preference.v1\0".utf8)
    let key = ValueBoxKey(length: namespace.count + 16)
    key.setData(0, value: namespace)
    key.setInt64(namespace.count, value: accountID)
    key.setInt64(namespace.count + 8, value: chatID)
    return key
}
private func archiveInstallReceipt(expectedRevision: UUID, encoded: Data) -> Data {
    Data("Makosh.PendingUpload.ArchiveInstall.v1\n".utf8) +
        Data(expectedRevision.uuidString.utf8) + Data(SHA256.hash(data: encoded))
}
private func encodePendingUpload(_ value: TelegramPendingUploadDraft) -> Data? {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    guard let bytes = try? encoder.encode(value), bytes.count <= 512 * 1024 - pendingUploadMarker.count else { return nil }
    return bytes
}
private func decodePendingUpload(_ data: Data, accountID: Int64, chatID: Int64) -> TelegramPendingUploadDraft? {
    guard data.count <= 512 * 1024, data.starts(with: pendingUploadMarker),
          let value = try? JSONDecoder().decode(TelegramPendingUploadDraft.self, from: data.dropFirst(pendingUploadMarker.count)),
          value.isValid, value.accountID == accountID, value.chatID == chatID else { return nil }
    return value
}
nonisolated func telegramPendingUploadRead(transaction: Transaction, accountID: Int64, chatID: Int64) -> Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError> {
    guard let entry = transaction.getPreferencesEntry(key: telegramPendingUploadKey(accountID: accountID, chatID: chatID)) else { return .success(nil) }
    guard let draft = decodePendingUpload(entry.data, accountID: accountID, chatID: chatID) else { return .failure(.incompatibleData) }
    return .success(draft)
}
nonisolated func telegramPendingUploadWrite(transaction: Transaction, accountID: Int64, draft: TelegramPendingUploadDraft, expectedRevision: UUID?) -> Result<Void, TelegramPendingUploadPersistenceError> {
    guard draft.isValid, draft.accountID == accountID else { return .failure(.incompatibleData) }
    guard let encoded = encodePendingUpload(draft) else { return .failure(.incompatibleData) }
    let key = telegramPendingUploadKey(accountID: accountID, chatID: draft.chatID)
    if let entry = transaction.getPreferencesEntry(key: key) {
        guard let current = decodePendingUpload(entry.data, accountID: accountID, chatID: draft.chatID) else { return .failure(.incompatibleData) }
        // JSON bytes preserve opaque strings exactly, unlike canonical String equality.
        if encodePendingUpload(current) == encoded { return .success(()) }
        guard current.revision == expectedRevision, draft.revision != current.revision else { return .failure(.conflict) }
    } else if expectedRevision != nil { return .failure(.conflict) }
    transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: pendingUploadMarker + encoded))
    // Even restoring an earlier UUID must not revive a prior install receipt.
    // Exact idempotent writes returned above; guarded installs set a new receipt
    // after this write, within the same transaction.
    let receiptKey = telegramPendingUploadArchiveInstallKey(accountID: accountID, chatID: draft.chatID)
    if transaction.getPreferencesEntry(key: receiptKey) != nil {
        transaction.setPreferencesEntry(key: receiptKey, value: nil)
    }
    let captureKey = telegramPendingUploadArchiveCaptureKey(accountID: accountID, chatID: draft.chatID)
    if transaction.getPreferencesEntry(key: captureKey) != nil {
        transaction.setPreferencesEntry(key: captureKey, value: nil)
    }
    let intentKey = telegramPendingUploadArchiveIntentKey(accountID: accountID, chatID: draft.chatID)
    if transaction.getPreferencesEntry(key: intentKey) != nil {
        transaction.setPreferencesEntry(key: intentKey, value: nil)
    }
    return .success(())
}
nonisolated func telegramPendingUploadArchiveWrite(transaction: Transaction, accountID: Int64,
    draft: TelegramPendingUploadDraft, expectedRevision: UUID, admission: TelegramPendingUploadArchiveAdmission)
    -> Result<Void, TelegramPendingUploadPersistenceError> {
    admission.withAdmission(accountID: accountID, chatID: draft.chatID, preparationID: draft.id, expectedRevision: expectedRevision) {
        guard draft.isValid, draft.accountID == accountID, draft.schemaVersion == 16,
              draft.presentation == .archive, draft.disposition == .prepared,
              let archive = draft.archive, let encoded = encodePendingUpload(draft) else { return .failure(.incompatibleData) }
        guard draft.revision != expectedRevision else { return .failure(.conflict) }
        switch telegramPendingUploadRead(transaction: transaction, accountID: accountID, chatID: draft.chatID) {
        case let .failure(error): return .failure(error)
        case let .success(current):
            guard let current else { return .failure(.conflict) }
            let receiptKey = telegramPendingUploadArchiveInstallKey(accountID: accountID, chatID: draft.chatID)
            let receipt = archiveInstallReceipt(expectedRevision: expectedRevision, encoded: encoded)
            // Replaying is read-only and requires the predecessor/candidate receipt
            // committed with the original pointer, even after a fresh Session/reopen.
            if encodePendingUpload(current) == encoded {
                guard transaction.getPreferencesEntry(key: receiptKey)?.data == receipt else { return .failure(.conflict) }
                return .success(())
            }
            guard current.schemaVersion == 15, current.disposition == .prepared,
                  current.revision == expectedRevision, current.id == draft.id,
                  telegramPendingUploadArchiveIntentMatches(transaction: transaction, current: current, candidate: draft,
                    requiredRecordID: admission.archiveIntentRecordID) else { return .failure(.conflict) }
            // Reconstruct from authoritative canonical state. Comparing encoded bytes
            // also preserves opaque UTF8 spellings, selections and record metadata.
            guard let expected = try? TelegramPendingUploadDraft(id: current.id, revision: draft.revision,
                accountID: current.accountID, chatID: current.chatID, title: current.title,
                captionInput: current.captionInput, originalDraft: current.originalDraft, replyTarget: current.replyTarget,
                items: current.items, isGrouped: false, presentation: .archive, archive: archive),
                encodePendingUpload(expected) == encoded else { return .failure(.conflict) }
            let result = telegramPendingUploadWrite(transaction: transaction, accountID: accountID,
                draft: draft, expectedRevision: expectedRevision)
            guard case .success = result else { return result }
            transaction.setPreferencesEntry(key: receiptKey, value: PreferencesEntry(data: receipt))
            return .success(())
        }
    }
}
private nonisolated func pendingUploadLoad(postbox: Postbox, accountID: Int64, chatID: Int64) -> Signal<Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>, NoError> {
    postbox.transaction { telegramPendingUploadRead(transaction: $0, accountID: accountID, chatID: chatID) }
}
private nonisolated func pendingUploadSave(postbox: Postbox, accountID: Int64, draft: TelegramPendingUploadDraft, expectedRevision: UUID?) -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    postbox.transaction { telegramPendingUploadWrite(transaction: $0, accountID: accountID, draft: draft, expectedRevision: expectedRevision) }
}
private nonisolated func pendingUploadArchiveCaptureLoad(postbox: Postbox, accountID: Int64, chatID: Int64)
    -> Signal<Result<TelegramPendingUploadArchiveCapture?, TelegramPendingUploadPersistenceError>, NoError> {
    postbox.transaction { telegramPendingUploadArchiveCaptureRead(transaction: $0, accountID: accountID, chatID: chatID) }
}
private nonisolated func pendingUploadArchiveIntentLoad(postbox: Postbox, accountID: Int64, chatID: Int64)
    -> Signal<Result<TelegramPendingUploadArchiveIntent?, TelegramPendingUploadPersistenceError>, NoError> {
    postbox.transaction { telegramPendingUploadArchiveIntentRead(transaction: $0, accountID: accountID, chatID: chatID) }
}
private nonisolated func pendingUploadArchiveIntentSave(postbox: Postbox, accountID: Int64, chatID: Int64,
    intent: TelegramPendingUploadArchiveIntent, admission: TelegramPendingUploadArchiveAdmission)
    -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    postbox.transaction { telegramPendingUploadArchiveIntentWrite(transaction: $0, accountID: accountID, chatID: chatID,
        intent: intent, admission: admission) }
}
private nonisolated func pendingUploadArchiveCaptureSave(postbox: Postbox, accountID: Int64,
    draft: TelegramPendingUploadDraft, expectedRevision: UUID, admission: TelegramPendingUploadArchiveAdmission)
    -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    postbox.transaction { telegramPendingUploadArchiveCaptureWrite(transaction: $0, accountID: accountID,
        draft: draft, expectedRevision: expectedRevision, admission: admission) }
}
private nonisolated func pendingUploadInstallArchive(postbox: Postbox, accountID: Int64,
    draft: TelegramPendingUploadDraft, expectedRevision: UUID, admission: TelegramPendingUploadArchiveAdmission)
    -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    postbox.transaction { telegramPendingUploadArchiveWrite(transaction: $0, accountID: accountID,
        draft: draft, expectedRevision: expectedRevision, admission: admission) }
}
@MainActor internal final class TelegramPostboxPendingUploadRepository: TelegramPendingUploadRepository {
    let accountID: Int64
    private let postbox: Postbox
    init(postbox: Postbox, accountID: Int64) { self.postbox = postbox; self.accountID = accountID }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        (pendingUploadLoad(postbox: postbox, accountID: accountID, chatID: chatID) |> deliverOnMainQueue).start(next: { result in
            MainActor.assumeIsolated { completion(result) }
        })
    }
    func save(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID?, completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        // Completion is engine transaction completion, not an fsync/disk-full promise.
        let _ = (pendingUploadSave(postbox: postbox, accountID: accountID, draft: draft, expectedRevision: expectedRevision)
            |> deliverOnMainQueue).startStandalone(next: { result in MainActor.assumeIsolated { completion(result) } })
    }
    func loadArchiveIntent(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveIntent?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        (pendingUploadArchiveIntentLoad(postbox: postbox, accountID: accountID, chatID: chatID) |> deliverOnMainQueue)
            .start(next: { result in MainActor.assumeIsolated { completion(result) } })
    }
    func retainArchiveIntent(_ intent: TelegramPendingUploadArchiveIntent, chatID: Int64, admission: TelegramPendingUploadArchiveAdmission,
                             completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        let _ = (pendingUploadArchiveIntentSave(postbox: postbox, accountID: accountID, chatID: chatID, intent: intent,
            admission: admission) |> deliverOnMainQueue)
            .startStandalone(next: { result in MainActor.assumeIsolated { completion(result) } })
    }
    func loadArchiveCapture(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadArchiveCapture?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        (pendingUploadArchiveCaptureLoad(postbox: postbox, accountID: accountID, chatID: chatID) |> deliverOnMainQueue)
            .start(next: { result in MainActor.assumeIsolated { completion(result) } })
    }
    func retainArchiveCapture(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID,
                              admission: TelegramPendingUploadArchiveAdmission,
                              completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        let _ = (pendingUploadArchiveCaptureSave(postbox: postbox, accountID: accountID, draft: draft,
            expectedRevision: expectedRevision, admission: admission) |> deliverOnMainQueue)
            .startStandalone(next: { result in MainActor.assumeIsolated { completion(result) } })
    }
    func installArchive(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID,
                        admission: TelegramPendingUploadArchiveAdmission,
                        completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        // The admission check executes on the native queue, together with the CAS.
        let _ = (pendingUploadInstallArchive(postbox: postbox, accountID: accountID, draft: draft,
            expectedRevision: expectedRevision, admission: admission) |> deliverOnMainQueue)
            .startStandalone(next: { result in MainActor.assumeIsolated { completion(result) } })
    }
}
