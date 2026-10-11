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
func decodeComposerDraft(_ entry: PreferencesEntry, accountID: Int64, chatID: Int64) -> TelegramComposerDraft? {
    guard entry.data.count <= 512 * 1024, entry.data.starts(with: composerDraftMarker),
          let value = try? JSONDecoder().decode(TelegramComposerDraft.self, from: entry.data.dropFirst(composerDraftMarker.count)),
          value.isValid, value.accountID == accountID, value.chatID == chatID,
          value.text.utf8.count <= 64 * 1024 else { return nil }
    return value
}

nonisolated func telegramComposerDraftRead(transaction: Transaction, accountID: Int64, chatID: Int64) -> Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError> {
    let key = PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(chatID))
    guard let entry = transaction.getPreferencesEntry(key: key) else { return .success(nil) }
    guard let value = decodeComposerDraft(entry, accountID: accountID, chatID: chatID) else { return .failure(.incompatibleData) }
    return .success(value)
}
private nonisolated func composerDraftEntry(_ draft: TelegramComposerDraft) -> PreferencesEntry? {
    guard draft.isValid, let encoded = try? JSONEncoder().encode(draft), encoded.count <= 512 * 1024 - composerDraftMarker.count else { return nil }
    return PreferencesEntry(data: composerDraftMarker + encoded)
}
private nonisolated func writeComposerDraft(transaction: Transaction, draft: TelegramComposerDraft) -> Bool {
    guard let entry = composerDraftEntry(draft) else { return false }
    transaction.setPreferencesEntry(key: PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(draft.chatID)),
        value: entry)
    return true
}
/// Prepare both CAS validation and bytes without writing. The caller commits
/// this alongside its queue receipt; ordinary input, selection and reply survive.
nonisolated func telegramPreparedForwardRemoval(transaction: Transaction, accountID: Int64, chatID: Int64,
                                                revision: UUID, intentID: UUID, sources: [TelegramComposerForwardSource]) -> (key: ValueBoxKey, entry: PreferencesEntry)? {
    guard case let .success(current?) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: chatID),
          current.revision == revision, current.forwardDisposition == .prepared,
          current.forwardIntent?.id == intentID, current.forwardIntent?.sources == sources else { return nil }
    let cleared = TelegramComposerDraft(accountID: accountID, chatID: chatID, input: current.input, replyTarget: current.replyTarget)
    guard let entry = composerDraftEntry(cleared) else { return nil }
    return (PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(chatID)), entry)
}
private nonisolated func composerDraftLoad(postbox: Postbox, accountID: Int64, chatID: Int64) -> Signal<Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { telegramComposerDraftRead(transaction: $0, accountID: accountID, chatID: chatID) }
}
private nonisolated func composerDraftSave(postbox: Postbox, accountID: Int64, draft: TelegramComposerDraft) -> Signal<Result<Void, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { transaction in
        guard draft.isValid, draft.accountID == accountID else { return .failure(.incompatibleData) }
        switch telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID) {
        case .failure: return .failure(.incompatibleData)
        case let .success(current):
            if let current {
                if current == draft { return .success(()) }
                // Ordinary save is not CAS. Only the transaction helpers may
                // mutate a started/accepted forward operation.
                guard current.forwardCanMutate else { return .failure(.incompatibleData) }
            }
            guard draft.forwardCanMutate else { return .failure(.incompatibleData) }
        }
        return writeComposerDraft(transaction: transaction, draft: draft) ? .success(()) : .failure(.unavailable)
    }
}
private nonisolated func forwardDraft(_ draft: TelegramComposerDraft, disposition: TelegramComposerForwardDisposition) -> TelegramComposerDraft {
    TelegramComposerDraft(accountID: draft.accountID, chatID: draft.chatID, input: draft.input, revision: draft.revision,
        replyTarget: draft.replyTarget, forwardIntent: draft.forwardIntent, forwardDisposition: disposition)
}
nonisolated func telegramForwardBeginSubmission(transaction: Transaction, accountID: Int64, draft: TelegramComposerDraft) -> Bool {
    guard draft.isValid, draft.accountID == accountID, draft.forwardIntent != nil, draft.forwardDisposition == .prepared,
          case let .success(current) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID),
          current == draft else { return false }
    return writeComposerDraft(transaction: transaction, draft: forwardDraft(draft, disposition: .submissionStarted))
}
nonisolated func telegramForwardRecordAcceptance(transaction: Transaction, accountID: Int64, draft: TelegramComposerDraft, ids: [TelegramForwardQueueID]) -> Bool {
    guard draft.isValid, draft.accountID == accountID, draft.forwardIntent != nil, draft.validForwardQueueIDs(ids),
          draft.forwardDisposition == .prepared || draft.forwardDisposition == .submissionStarted,
          case let .success(current) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID),
          current == forwardDraft(draft, disposition: .submissionStarted) else { return false }
    return writeComposerDraft(transaction: transaction, draft: forwardDraft(draft, disposition: .accepted(ids)))
}
nonisolated func telegramForwardResetRejected(postbox: Postbox, accountID: Int64, draft: TelegramComposerDraft) -> Signal<Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { transaction in
        guard draft.isValid, draft.accountID == accountID, draft.forwardIntent != nil,
              draft.forwardDisposition == .prepared || draft.forwardDisposition == .submissionStarted,
              case let .success(current) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID),
              current == forwardDraft(draft, disposition: .submissionStarted) else { return .failure(.incompatibleData) }
        let updated = forwardDraft(draft, disposition: .prepared)
        return writeComposerDraft(transaction: transaction, draft: updated) ? .success(updated) : .failure(.unavailable)
    }
}
nonisolated func telegramForwardConsumeAccepted(postbox: Postbox, accountID: Int64, draft: TelegramComposerDraft) -> Signal<Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { transaction in
        guard draft.isValid, draft.accountID == accountID, case .accepted = draft.forwardDisposition,
              case let .success(current) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID),
              current == draft else { return .failure(.incompatibleData) }
        let updated = TelegramComposerDraft(accountID: accountID, chatID: draft.chatID, input: .empty)
        return writeComposerDraft(transaction: transaction, draft: updated) ? .success(updated) : .failure(.unavailable)
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
