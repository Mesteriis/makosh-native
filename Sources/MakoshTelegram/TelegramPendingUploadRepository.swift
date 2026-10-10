import Foundation
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
private nonisolated func pendingUploadLoad(postbox: Postbox, accountID: Int64, chatID: Int64) -> Signal<Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>, NoError> {
    postbox.transaction { transaction in
        guard let entry = transaction.getPreferencesEntry(key: telegramPendingUploadKey(accountID: accountID, chatID: chatID)) else { return .success(nil) }
        guard let draft = decodePendingUpload(entry.data, accountID: accountID, chatID: chatID) else { return .failure(.incompatibleData) }
        return .success(draft)
    }
}
private nonisolated func pendingUploadSave(postbox: Postbox, accountID: Int64, draft: TelegramPendingUploadDraft, expectedRevision: UUID?) -> Signal<Result<Void, TelegramPendingUploadPersistenceError>, NoError> {
    postbox.transaction { transaction in
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
        return .success(())
    }
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
}
