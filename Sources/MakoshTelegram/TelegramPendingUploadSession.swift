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

    func replaceVideoCover(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                           cover: TelegramUploadVideoCover?) async throws {
        guard target.accountID == accountID, target.hasValidReplySource, file.mode == .video,
              file.video?.isValid(name: file.name, size: file.size) == true else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        // Freeze the owned inode before suspension. The account-bound write can
        // finish after the editor/window releases its temporary path.
        let capture = try cover.map(TelegramPendingUploadFiles.captureCover)
        try await serial { [self] in
            guard let current = try await read(chatID: target.chatID), current.id == preparationID,
                  current.schemaVersion < 6, current.disposition == .prepared, current.file.attachment.kind == "video",
                  current.file.attachment.name.utf8.elementsEqual(file.name.utf8),
                  current.file.plaintextByteCount == file.size, current.video == file.video,
                  current.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            // A lost ACK may already have installed this exact cover. Reuse its
            // object instead of appending another copy or reverting to the old one.
            if telegramPendingUploadCoverMatches(current.videoCover, cover) { return }
            guard telegramPendingUploadCoverMatches(current.videoCover, file.videoCover) else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            let saved: TelegramPendingUploadVideoCover?
            if let cover, let capture {
                saved = try await files().saveCover(cover, accountID: accountID, chatID: target.chatID,
                    preparationID: preparationID, capture: capture)
            } else { saved = nil }
            let updated = TelegramPendingUploadDraft(id: current.id, accountID: accountID, chatID: current.chatID,
                title: current.title, captionInput: current.captionInput, captionAboveMedia: current.captionAboveMedia,
                mediaSpoiler: current.mediaSpoiler, originalDraft: current.originalDraft,
                replyTarget: current.replyTarget, file: current.file, video: current.video, videoCover: saved)
            try await write(updated, expectedRevision: current.revision)
        }
    }

    func prepare(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                 captionInput: TelegramComposerInput, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false, originalDraft: TelegramComposerDraft?) async throws {
        try await serial { [self] in
            guard target.accountID == accountID, target.hasValidReplySource, (!captionAboveMedia && !mediaSpoiler) || file.mode != .file,
                  file.mode == .video || file.videoCover == nil else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            let previous = try await read(chatID: target.chatID)
            if let previous, previous.id == preparationID {
                // Retrying an unconfirmed pointer write must reuse its stored file.
                guard previous.schemaVersion < 6, previous.disposition == .prepared, previous.originalDraft == originalDraft,
                      previous.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)),
                      previous.file.attachment.name == file.name, previous.file.plaintextByteCount == file.size,
                      previous.file.attachment.kind == file.mode.rawValue, previous.video == file.video,
                      telegramPendingUploadCoverMatches(previous.videoCover, file.videoCover) else {
                    throw TelegramPendingUploadPersistenceError.conflict
                }
                guard try await files().matches(file: file, record: previous.file) else {
                    throw TelegramPendingUploadPersistenceError.conflict
                }
                let updated = TelegramPendingUploadDraft(id: preparationID, accountID: accountID, chatID: target.chatID,
                    title: target.title, captionInput: captionInput, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler, originalDraft: originalDraft,
                    replyTarget: previous.replyTarget, file: previous.file, video: previous.video, videoCover: previous.videoCover)
                try await write(updated, expectedRevision: previous.revision)
                return
            }
            if let previous {
                switch previous.disposition {
                case .accepted, .acceptedBatch, .cancelled: break
                case .prepared, .submissionStarted: throw TelegramPendingUploadPersistenceError.conflict
                }
            }
            let storage = try files()
            let record = try await storage.save(file: file, accountID: accountID,
                chatID: target.chatID, preparationID: preparationID)
            let cover: TelegramPendingUploadVideoCover?
            if let staged = file.videoCover {
                cover = try await storage.saveCover(staged, accountID: accountID, chatID: target.chatID, preparationID: preparationID)
            } else { cover = nil }
            let draft = TelegramPendingUploadDraft(id: preparationID, accountID: accountID, chatID: target.chatID,
                title: target.title, captionInput: captionInput, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler, originalDraft: originalDraft,
                replyTarget: target.replySource.map(TelegramComposerReplyTarget.init(source:)), file: record, video: file.video, videoCover: cover)
            try await write(draft, expectedRevision: previous?.revision)
        }
    }

    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, target: TelegramUploadTarget,
                 captionInput: TelegramComposerInput, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false,
                 originalDraft: TelegramComposerDraft?) async throws {
        try await serial { [self] in
            guard target.accountID == accountID, target.hasValidReplySource, !items.isEmpty,
                  preparationID != TelegramPendingUploadDraft.zeroUUID,
                  Set(items.map(\.id)).count == items.count,
                  items.allSatisfy({ $0.id != TelegramPendingUploadDraft.zeroUUID &&
                      ((!captionAboveMedia && !mediaSpoiler) || $0.file.mode != .file) &&
                      ($0.file.mode == .video || $0.file.videoCover == nil) }) else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            let previous = try await read(chatID: target.chatID)
            if let previous, previous.id == preparationID {
                guard previous.schemaVersion == 6, previous.disposition == .prepared,
                      previous.originalDraft == originalDraft, previous.isGrouped == isGrouped,
                      previous.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)),
                      previous.items.count == items.count,
                      zip(previous.items, items).allSatisfy({ stored, staged in
                          stored.id == staged.id && stored.file.attachment.name.utf8.elementsEqual(staged.file.name.utf8) &&
                          stored.file.plaintextByteCount == staged.file.size && stored.file.attachment.kind == staged.file.mode.rawValue &&
                          stored.video == staged.file.video && telegramPendingUploadCoverMatches(stored.videoCover, staged.file.videoCover)
                      }) else { throw TelegramPendingUploadPersistenceError.conflict }
                let storage = try files()
                for (stored, staged) in zip(previous.items, items) {
                    guard try await storage.matches(file: staged.file, record: stored.file) else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                }
                try await write(previous.updating(captionInput: captionInput, captionAboveMedia: captionAboveMedia,
                    mediaSpoiler: mediaSpoiler, disposition: .prepared), expectedRevision: previous.revision)
                return
            }
            if let previous {
                switch previous.disposition {
                case .accepted, .acceptedBatch, .cancelled: break
                case .prepared, .submissionStarted: throw TelegramPendingUploadPersistenceError.conflict
                }
            }
            let captures = try items.map { try TelegramPendingUploadFiles.captureFile($0.file) }
            let covers = try items.map { try $0.file.videoCover.map(TelegramPendingUploadFiles.captureCover) }
            let storage = try files()
            var stored: [TelegramPendingUploadItem] = []
            for (index, item) in items.enumerated() {
                let record = try await storage.save(file: item.file, accountID: accountID, chatID: target.chatID,
                    preparationID: preparationID, itemID: item.id, capture: captures[index])
                let cover: TelegramPendingUploadVideoCover?
                if let staged = item.file.videoCover {
                    cover = try await storage.saveCover(staged, accountID: accountID, chatID: target.chatID,
                        preparationID: preparationID, itemID: item.id, capture: covers[index])
                } else { cover = nil }
                stored.append(.init(id: item.id, file: record, video: item.file.video, videoCover: cover))
            }
            let draft = try TelegramPendingUploadDraft(id: preparationID, accountID: accountID, chatID: target.chatID,
                title: target.title, captionInput: captionInput, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler,
                originalDraft: originalDraft, replyTarget: target.replySource.map(TelegramComposerReplyTarget.init(source:)),
                items: stored, isGrouped: isGrouped)
            try await write(draft, expectedRevision: previous?.revision)
        }
    }

    func save(preparationID: UUID, chatID: Int64, captionInput: TelegramComposerInput, captionAboveMedia: Bool = false, mediaSpoiler: Bool = false,
              disposition: TelegramPendingUploadDisposition) async throws {
        try await serial { [self] in
            guard let current = try await read(chatID: chatID) else {
                if disposition == .cancelled { return } // Cancel before the initial pointer exists.
                throw TelegramPendingUploadPersistenceError.conflict
            }
            guard current.id == preparationID, Self.permits(from: current.disposition, to: disposition) else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            let updated = current.updating(captionInput: captionInput, captionAboveMedia: captionAboveMedia,
                mediaSpoiler: mediaSpoiler, disposition: disposition)
            try await write(updated, expectedRevision: current.revision)
        }
    }

    func restoreFile(draft: TelegramPendingUploadDraft) async throws -> TelegramUploadFile {
        guard draft.isValid, draft.schemaVersion < 6, draft.accountID == accountID else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        return try await restoreItems(draft: draft)[0].file
    }

    func restoreItems(draft: TelegramPendingUploadDraft) async throws -> [TelegramUploadBatchItem] {
        guard draft.isValid, draft.accountID == accountID else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        let storage = try files()
        var restored: [TelegramUploadBatchItem] = []
        do {
            for item in draft.items {
                let itemID = draft.schemaVersion == 6 ? item.id : nil
                let file = try await storage.restore(record: item.file, accountID: accountID,
                    chatID: draft.chatID, preparationID: draft.id, video: item.video, itemID: itemID)
                // Register each stage before cover export so every failure cleans it.
                restored.append(.init(id: item.id, file: file))
                if let saved = item.videoCover {
                    let cover = try await storage.restoreCover(saved, accountID: accountID, chatID: draft.chatID,
                        preparationID: draft.id, itemID: itemID)
                    restored[restored.count - 1] = .init(id: item.id, file: TelegramUploadFile(id: file.id, name: file.name,
                        size: file.size, mode: file.mode, pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight,
                        url: file.url, directory: file.directory, video: file.video, videoCover: cover))
                }
            }
            return restored
        } catch {
            for item in restored { try? TelegramUploadFileIO.discard(item.file) }
            throw error
        }
    }

    private static func permits(from: TelegramPendingUploadDisposition, to: TelegramPendingUploadDisposition) -> Bool {
        switch (from, to) {
        case (.prepared, .prepared), (.prepared, .submissionStarted), (.prepared, .cancelled),
             (.submissionStarted, .submissionStarted), (.submissionStarted, .accepted),
             (.submissionStarted, .cancelled), (.cancelled, .cancelled): return true
        case let (.accepted(old), .accepted(new)): return old.utf8.elementsEqual(new.utf8)
        case let (.acceptedBatch(old), .acceptedBatch(new)): return old == new
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
