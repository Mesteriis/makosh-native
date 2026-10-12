import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

internal enum TelegramComposerDraftPersistenceError: Error, LocalizedError, Equatable {
    case unavailable, incompatibleData, serverConflict
    var errorDescription: String? {
        switch self {
        case .unavailable: "Не удалось сохранить или загрузить черновик."
        case .incompatibleData: "Сохранённый черновик имеет несовместимый формат. Данные не изменены."
        case .serverConflict: "Черновик изменился на другом устройстве. Автоматическая перезапись остановлена; текущий текст оставлен в редакторе."
        }
    }
}

@MainActor internal protocol TelegramComposerDraftRepository: AnyObject {
    var accountID: Int64 { get }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable
    func load(chatID: Int64, threadID: Int64?, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable
    func save(_ draft: TelegramComposerDraft, completion: @escaping @MainActor (Result<Void, TelegramComposerDraftPersistenceError>) -> Void)
}

extension TelegramComposerDraftRepository {
    func load(chatID: Int64, threadID: Int64?, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
        guard threadID == nil else { completion(.failure(.unavailable)); return EmptyDisposable }
        return load(chatID: chatID, completion: completion)
    }
}

nonisolated func telegramComposerDraftKey(accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> ValueBoxKey {
    guard let threadID else { return PreferencesKeys.persistentChatInterfaceData(peerId: PeerId(chatID)) }
    let namespace = Data("Makosh.ComposerDraft.Topic.v1\0".utf8)
    let key = ValueBoxKey(length: namespace.count + 24)
    key.setData(0, value: namespace); key.setInt64(namespace.count, value: accountID)
    key.setInt64(namespace.count + 8, value: chatID); key.setInt64(namespace.count + 16, value: threadID)
    return key
}

// Opaque engine preference payload; do not invoke the legacy Postbox decoder on
// unknown bytes. A distinct marker prevents overwriting another client's state.
private let composerDraftMarker = Data("MakoshComposerDraft.v1\n".utf8)
func decodeComposerDraft(_ entry: PreferencesEntry, accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> TelegramComposerDraft? {
    guard entry.data.count <= 512 * 1024, entry.data.starts(with: composerDraftMarker),
          let value = try? JSONDecoder().decode(TelegramComposerDraft.self, from: entry.data.dropFirst(composerDraftMarker.count)),
          value.isValid, value.accountID == accountID, value.chatID == chatID, value.threadID == threadID,
          value.text.utf8.count <= 64 * 1024 else { return nil }
    return value
}

nonisolated func telegramComposerDraftRead(transaction: Transaction, accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError> {
    let key = telegramComposerDraftKey(accountID: accountID, chatID: chatID, threadID: threadID)
    guard let entry = transaction.getPreferencesEntry(key: key) else { return .success(nil) }
    guard let value = decodeComposerDraft(entry, accountID: accountID, chatID: chatID, threadID: threadID) else { return .failure(.incompatibleData) }
    return .success(value)
}
private nonisolated func composerDraftEntry(_ draft: TelegramComposerDraft) -> PreferencesEntry? {
    guard draft.isValid, let encoded = try? JSONEncoder().encode(draft), encoded.count <= 512 * 1024 - composerDraftMarker.count else { return nil }
    return PreferencesEntry(data: composerDraftMarker + encoded)
}
nonisolated func telegramComposerDraftWriteLocal(transaction: Transaction, draft: TelegramComposerDraft) -> Bool {
    guard let entry = composerDraftEntry(draft) else { return false }
    transaction.setPreferencesEntry(key: telegramComposerDraftKey(accountID: draft.accountID, chatID: draft.chatID, threadID: draft.threadID),
        value: entry)
    return true
}
/// Prepare both CAS validation and bytes without writing. The caller commits
/// this alongside its queue receipt; ordinary input, selection and reply survive.
nonisolated func telegramPreparedForwardRemoval(transaction: Transaction, accountID: Int64, chatID: Int64,
                                                threadID: Int64? = nil, revision: UUID, intentID: UUID, sources: [TelegramComposerForwardSource]) -> (key: ValueBoxKey, entry: PreferencesEntry)? {
    guard case let .success(current?) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID),
          current.revision == revision, current.forwardDisposition == .prepared,
          current.forwardIntent?.id == intentID, current.forwardIntent?.sources == sources else { return nil }
    let cleared = TelegramComposerDraft(accountID: accountID, chatID: chatID, input: current.input,
        threadID: current.threadID, replyTarget: current.replyTarget)
    guard let entry = composerDraftEntry(cleared) else { return nil }
    return (telegramComposerDraftKey(accountID: accountID, chatID: chatID, threadID: threadID), entry)
}
private nonisolated func composerDraftLoad(postbox: Postbox, accountID: Int64, chatID: Int64, threadID: Int64? = nil) -> Signal<Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { transaction in
        do {
            let local = try telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID).get()
            return .success(try telegramServerDraftReconcile(transaction: transaction, accountID: accountID, chatID: chatID, threadID: threadID, local: local))
        } catch let error as TelegramComposerDraftPersistenceError { return .failure(error) }
        catch { return .failure(.incompatibleData) }
    }
}
private nonisolated func composerDraftSave(postbox: Postbox, accountID: Int64, draft: TelegramComposerDraft) -> Signal<Result<Void, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { transaction in
        guard draft.isValid, draft.accountID == accountID else { return .failure(.incompatibleData) }
        switch telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID, threadID: draft.threadID) {
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
        guard composerDraftEntry(draft) != nil else { return .failure(.incompatibleData) }
        do { try telegramServerDraftWrite(transaction: transaction, draft: draft) }
        catch let error as TelegramComposerDraftPersistenceError { return .failure(error) }
        catch { return .failure(.incompatibleData) }
        return telegramComposerDraftWriteLocal(transaction: transaction, draft: draft) ? .success(()) : .failure(.unavailable)
    }
}
private nonisolated func resolveServerDraft(postbox: Postbox, accountID: Int64, update: TelegramServerDraftUpdate,
    local: TelegramComposerDraft?, choice: TelegramServerDraftChoice) -> Signal<Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction {
        guard update.draft.accountID == accountID else { return .failure(.incompatibleData) }
        do { return .success(try telegramServerDraftResolve(transaction: $0, update: update, local: local, choice: choice)) }
        catch let error as TelegramComposerDraftPersistenceError { return .failure(error) }
        catch { return .failure(.incompatibleData) }
    }
}
private nonisolated func forwardDraft(_ draft: TelegramComposerDraft, disposition: TelegramComposerForwardDisposition) -> TelegramComposerDraft {
    TelegramComposerDraft(accountID: draft.accountID, chatID: draft.chatID, input: draft.input, revision: draft.revision, threadID: draft.threadID,
        replyTarget: draft.replyTarget, forwardIntent: draft.forwardIntent, forwardDisposition: disposition)
}
nonisolated func telegramForwardBeginSubmission(transaction: Transaction, accountID: Int64, draft: TelegramComposerDraft) -> Bool {
    guard draft.isValid, draft.accountID == accountID, draft.forwardIntent != nil, draft.forwardDisposition == .prepared,
          case let .success(current) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID, threadID: draft.threadID),
          current == draft else { return false }
    return telegramComposerDraftWriteLocal(transaction: transaction, draft: forwardDraft(draft, disposition: .submissionStarted))
}
nonisolated func telegramForwardRecordAcceptance(transaction: Transaction, accountID: Int64, draft: TelegramComposerDraft, ids: [TelegramForwardQueueID]) -> Bool {
    guard draft.isValid, draft.accountID == accountID, draft.forwardIntent != nil, draft.validForwardQueueIDs(ids),
          draft.forwardDisposition == .prepared || draft.forwardDisposition == .submissionStarted,
          case let .success(current) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID, threadID: draft.threadID),
          current == forwardDraft(draft, disposition: .submissionStarted) else { return false }
    return telegramComposerDraftWriteLocal(transaction: transaction, draft: forwardDraft(draft, disposition: .accepted(ids)))
}
nonisolated func telegramForwardResetRejected(postbox: Postbox, accountID: Int64, draft: TelegramComposerDraft) -> Signal<Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { transaction in
        guard draft.isValid, draft.accountID == accountID, draft.forwardIntent != nil,
              draft.forwardDisposition == .prepared || draft.forwardDisposition == .submissionStarted,
              case let .success(current) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID, threadID: draft.threadID),
              current == forwardDraft(draft, disposition: .submissionStarted) else { return .failure(.incompatibleData) }
        let updated = forwardDraft(draft, disposition: .prepared)
        return telegramComposerDraftWriteLocal(transaction: transaction, draft: updated) ? .success(updated) : .failure(.unavailable)
    }
}
nonisolated func telegramForwardConsumeAccepted(postbox: Postbox, accountID: Int64, draft: TelegramComposerDraft) -> Signal<Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>, NoError> {
    postbox.transaction { transaction in
        guard draft.isValid, draft.accountID == accountID, case .accepted = draft.forwardDisposition,
              case let .success(current) = telegramComposerDraftRead(transaction: transaction, accountID: accountID, chatID: draft.chatID, threadID: draft.threadID),
              current == draft else { return .failure(.incompatibleData) }
        let updated = TelegramComposerDraft(accountID: accountID, chatID: draft.chatID, input: .empty, threadID: draft.threadID)
        return telegramComposerDraftWriteLocal(transaction: transaction, draft: updated) ? .success(updated) : .failure(.unavailable)
    }
}

@MainActor internal final class TelegramPostboxComposerDraftRepository: TelegramComposerDraftRepository, TelegramServerDraftResolving {
    let accountID: Int64
    private let postbox: Postbox
    init(postbox: Postbox, accountID: Int64) { self.postbox = postbox; self.accountID = accountID }
    func resolve(update: TelegramServerDraftUpdate, local: TelegramComposerDraft?, choice: TelegramServerDraftChoice,
        completion: @escaping @MainActor (Result<TelegramComposerDraft, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
        (resolveServerDraft(postbox: postbox, accountID: accountID, update: update, local: local, choice: choice)
            |> deliverOnMainQueue).start(next: { result in MainActor.assumeIsolated { completion(result) } })
    }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
        (composerDraftLoad(postbox: postbox, accountID: accountID, chatID: chatID) |> deliverOnMainQueue).start(next: { result in
            MainActor.assumeIsolated { completion(result) }
        })
    }
    func load(chatID: Int64, threadID: Int64?, completion: @escaping @MainActor (Result<TelegramComposerDraft?, TelegramComposerDraftPersistenceError>) -> Void) -> Disposable {
        (composerDraftLoad(postbox: postbox, accountID: accountID, chatID: chatID, threadID: threadID) |> deliverOnMainQueue).start(next: { result in
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
