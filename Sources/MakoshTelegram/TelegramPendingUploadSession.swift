import Foundation
import SwiftSignalKit

/// Serial account-bound writes continue against their original repository after
/// the UI goes away. Loading or restoring a record never enqueues a message.
@MainActor final class TelegramPendingUploadSession: TelegramUploadRecoveryStore {
    let accountID: Int64
    private let repository: any TelegramPendingUploadRepository
    private let files: @MainActor () throws -> TelegramPendingUploadFiles
    private var tail: Task<Void, Never>?

    init(repository: any TelegramPendingUploadRepository,
         files: @escaping @MainActor () throws -> TelegramPendingUploadFiles) {
        self.repository = repository; self.accountID = repository.accountID; self.files = files
    }

    func load(chatID: Int64) async throws -> TelegramPendingUploadDraft? {
        try await serial { [self] in try await read(chatID: chatID) }
    }

    func prepare(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                 captionInput: TelegramComposerInput, originalDraft: TelegramComposerDraft?) async throws {
        try await serial { [self] in
            guard target.accountID == accountID, target.hasValidReplySource else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            let previous = try await read(chatID: target.chatID)
            if let previous, previous.id == preparationID {
                // Retrying an unconfirmed pointer write must reuse its stored file.
                guard previous.disposition == .prepared, previous.originalDraft == originalDraft,
                      previous.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)),
                      previous.file.attachment.name == file.name, previous.file.plaintextByteCount == file.size,
                      previous.file.attachment.kind == (file.mode == .photo ? "photo" : "file") else {
                    throw TelegramPendingUploadPersistenceError.conflict
                }
                let updated = TelegramPendingUploadDraft(id: preparationID, accountID: accountID, chatID: target.chatID,
                    title: target.title, captionInput: captionInput, originalDraft: originalDraft,
                    replyTarget: previous.replyTarget, file: previous.file)
                try await write(updated, expectedRevision: previous.revision)
                return
            }
            if let previous {
                switch previous.disposition {
                case .accepted, .cancelled: break
                case .prepared, .submissionStarted: throw TelegramPendingUploadPersistenceError.conflict
                }
            }
            let record = try await files().save(file: file, accountID: accountID,
                chatID: target.chatID, preparationID: preparationID)
            let draft = TelegramPendingUploadDraft(id: preparationID, accountID: accountID, chatID: target.chatID,
                title: target.title, captionInput: captionInput, originalDraft: originalDraft,
                replyTarget: target.replySource.map(TelegramComposerReplyTarget.init(source:)), file: record)
            try await write(draft, expectedRevision: previous?.revision)
        }
    }

    func save(preparationID: UUID, chatID: Int64, captionInput: TelegramComposerInput,
              disposition: TelegramPendingUploadDisposition) async throws {
        try await serial { [self] in
            guard let current = try await read(chatID: chatID) else {
                if disposition == .cancelled { return } // Cancel before the initial pointer exists.
                throw TelegramPendingUploadPersistenceError.conflict
            }
            guard current.id == preparationID, Self.permits(from: current.disposition, to: disposition) else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            let updated = TelegramPendingUploadDraft(id: current.id, accountID: accountID, chatID: chatID,
                title: current.title, captionInput: captionInput, originalDraft: current.originalDraft,
                replyTarget: current.replyTarget, file: current.file, disposition: disposition)
            try await write(updated, expectedRevision: current.revision)
        }
    }

    func restoreFile(draft: TelegramPendingUploadDraft) async throws -> TelegramUploadFile {
        guard draft.isValid, draft.accountID == accountID else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        return try await files().restore(record: draft.file, accountID: accountID,
            chatID: draft.chatID, preparationID: draft.id)
    }

    private static func permits(from: TelegramPendingUploadDisposition, to: TelegramPendingUploadDisposition) -> Bool {
        switch (from, to) {
        case (.prepared, .prepared), (.prepared, .submissionStarted), (.prepared, .cancelled),
             (.submissionStarted, .submissionStarted), (.submissionStarted, .accepted),
             (.submissionStarted, .cancelled), (.cancelled, .cancelled): return true
        case let (.accepted(old), .accepted(new)): return old.utf8.elementsEqual(new.utf8)
        default: return false
        }
    }

    private func serial<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let previous = tail
        let result = Task { @MainActor in
            await previous?.value
            return try await operation()
        }
        tail = Task { @MainActor in _ = await result.result }
        return try await result.value
    }

    private func read(chatID: Int64) async throws -> TelegramPendingUploadDraft? {
        let result: TelegramPendingUploadDraft? = try await awaitResult { [repository] completion in
            repository.load(chatID: chatID, completion: completion)
        }
        guard result == nil || result?.accountID == accountID && result?.chatID == chatID && result?.isValid == true else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        return result
    }

    private func write(_ value: TelegramPendingUploadDraft, expectedRevision: UUID?) async throws {
        guard value.isValid, value.accountID == accountID else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        let _: Void = try await awaitResult { [repository] completion in
            repository.save(value, expectedRevision: expectedRevision, completion: completion)
            return nil
        }
    }

    private func awaitResult<Value: Sendable>(
        _ start: (@escaping @MainActor (Result<Value, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable?
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = TelegramPendingUploadWaiter(continuation)
            waiter.deadline = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                waiter.finish(.failure(.unavailable))
            }
            waiter.operation.set(start { result in waiter.finish(result) })
        }
    }
}

@MainActor private final class TelegramPendingUploadWaiter<Value: Sendable> {
    var deadline: Task<Void, Never>?
    let operation = MetaDisposable()
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, TelegramPendingUploadPersistenceError>) {
        guard let continuation else { return }
        self.continuation = nil; deadline?.cancel(); deadline = nil; operation.dispose()
        continuation.resume(with: result.mapError { $0 as any Error })
    }
}
