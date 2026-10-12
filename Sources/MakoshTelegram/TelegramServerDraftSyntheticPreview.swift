#if DEBUG
import Foundation
import SwiftSignalKit

/// Explicit UI-only conflict. It never opens Account/Postbox or sends a draft.
@MainActor final class TelegramServerDraftSyntheticPreview: TelegramComposerDraftRepository,
    TelegramServerDraftObserving, TelegramServerDraftResolving {
    let accountID: Int64 = -1
    let basis = TelegramComposerDraft(accountID: -1, chatID: 10004, text: "Исходный черновик")
    private var saved: TelegramComposerDraft?
    private var resolved = false
    init() { saved = basis }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
        completion(.success(chatID == basis.chatID ? saved : nil)); return EmptyDisposable
    }
    func save(_ draft: TelegramComposerDraft, completion: @escaping @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void) {
        guard draft.isValid, draft.accountID == accountID, draft.chatID == basis.chatID,
              draft.threadID == nil else { completion(.failure(.incompatibleData)); return }
        saved = draft; completion(.success(()))
    }
    func observe(chatID: Int64, context: TelegramServerDraftObservationContext,
        receive: @escaping @MainActor (TelegramServerDraftObservationEvent) -> Void) -> Disposable {
        guard !resolved, chatID == basis.chatID, context.accountID == accountID, context.threadID == nil else { return EmptyDisposable }
        let remote = TelegramComposerDraft(accountID: accountID, chatID: chatID, text: "Черновик с другого устройства 🦊")
        receive(.init(context: context, result: .success(.init(draft: remote,
            nativeFingerprint: Data("synthetic draft version".utf8), basisRevision: basis.revision,
            localRevision: saved?.revision))))
        return EmptyDisposable
    }
    func resolve(update: TelegramServerDraftUpdate, local: TelegramComposerDraft?, choice: TelegramServerDraftChoice,
        completion: @escaping @MainActor (Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
        guard !resolved, update.draft.accountID == accountID, update.draft.chatID == basis.chatID,
              update.draft.threadID == nil, local?.revision == saved?.revision else {
            completion(.failure(.serverConflict)); return EmptyDisposable
        }
        let chosen = choice == .local ? local : update.draft
        guard let chosen else { completion(.failure(.incompatibleData)); return EmptyDisposable }
        saved = chosen; resolved = true; completion(.success(chosen)); return EmptyDisposable
    }
}
#endif
