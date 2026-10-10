import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

internal enum TelegramComposerDraftPersistenceError: Error, LocalizedError, Equatable {
    case unavailable, incompatibleData
    var errorDescription: String? {
        switch self {
        case .unavailable: "Не удалось сохранить или загрузить черновик."
        case .incompatibleData: "Сохранённый черновик имеет несовместимый формат. Данные не изменены."
        }
    }
}

@MainActor internal protocol TelegramComposerDraftRepository: AnyObject {
    var accountID: Int64 { get }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable
    func save(_ draft: TelegramComposerDraft, completion: @escaping @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void)
}

// Opaque engine preference payload; do not invoke the legacy Postbox decoder on
// unknown bytes. A distinct marker prevents overwriting another client's state.
private let composerDraftMarker = Data("MakoshComposerDraft.v1\n".utf8)
private func decodeComposerDraft(_ entry: PreferencesEntry, accountID: Int64, chatID: Int64) -> TelegramComposerDraft? {
    guard entry.data.count <= 512 * 1024, entry.data.starts(with: composerDraftMarker),
          let value = try? JSONDecoder().decode(TelegramComposerDraft.self, from: entry.data.dropFirst(composerDraftMarker.count)),
          value.isValid, value.accountID == accountID, value.chatID == chatID,
          value.text.utf8.count <= 64 * 1024 else { return nil }
    return value
}

private func composerDraftLoad(postbox: Postbox, accountID: Int64, chatID: Int64) -> Signal<Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { transaction in
        let key = PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(chatID))
        guard let entry = transaction.getPreferencesEntry(key: key) else { return .success(nil) }
        guard let value = decodeComposerDraft(entry, accountID: accountID, chatID: chatID) else { return .failure(.incompatibleData) }
        return .success(value)
    }
}

private func composerDraftSave(postbox: Postbox, accountID: Int64, draft: TelegramComposerDraft) -> Signal<Result<Void, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { transaction in
        guard draft.isValid, draft.accountID == accountID, draft.text.utf8.count <= 64 * 1024 else { return .failure(.incompatibleData) }
        let key = PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(draft.chatID))
        if let existing = transaction.getPreferencesEntry(key: key),
           decodeComposerDraft(existing, accountID: accountID, chatID: draft.chatID) == nil { return .failure(.incompatibleData) }
        guard let encoded = try? JSONEncoder().encode(draft) else { return .failure(.unavailable) }
        let entry = CodableEntry(data: composerDraftMarker + encoded)
        transaction.setPreferencesEntry(key: key, value: PreferencesEntry(data: entry.data))
        return .success(())
    }
}

@MainActor internal final class TelegramPostboxComposerDraftRepository: TelegramComposerDraftRepository {
    let accountID: Int64
    private let postbox: Postbox
    init(postbox: Postbox, accountID: Int64) { self.postbox = postbox; self.accountID = accountID }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
        (composerDraftLoad(postbox: postbox, accountID: accountID, chatID: chatID) |> deliverOnMainQueue).start(next: { result in
            MainActor.assumeIsolated { completion(result) }
        })
    }
    func save(_ draft: TelegramComposerDraft, completion: @escaping @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void) {
        // Start now, retain through engine standalone lifetime, never cancel a
        // bound-account write merely because the UI switched account/chat.
        let _ = (composerDraftSave(postbox: postbox, accountID: accountID, draft: draft) |> deliverOnMainQueue).startStandalone(next: { result in
            MainActor.assumeIsolated { completion(result) }
        })
    }
}
