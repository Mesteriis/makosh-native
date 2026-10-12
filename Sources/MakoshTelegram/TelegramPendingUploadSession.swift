import Foundation
import MakoshCore
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

    func loadArchiveCapture(chatID: Int64) async throws -> TelegramPendingUploadArchiveCapture? {
        try await serial { [self] in try await readArchiveCapture(chatID: chatID) }
    }

    func installArchive(preparationID: UUID, expectedRevision: UUID, archive: TelegramPendingUploadArchive,
                        target: TelegramUploadTarget, admission: TelegramPendingUploadArchiveAdmission) async throws -> TelegramPendingUploadDraft {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try admission.check(accountID: accountID, chatID: target.chatID,
                preparationID: preparationID, expectedRevision: expectedRevision)
            guard target.accountID == accountID, target.hasValidReplySource else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            do {
                return try await serial { [self] in
                    try admission.check(accountID: accountID, chatID: target.chatID,
                        preparationID: preparationID, expectedRevision: expectedRevision)
                    let current = try await read(chatID: target.chatID)
                    try admission.check(accountID: accountID, chatID: target.chatID,
                        preparationID: preparationID, expectedRevision: expectedRevision)
                    guard let current, current.id == preparationID, current.disposition == .prepared,
                          current.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                    let candidate: TelegramPendingUploadDraft
                    if current.schemaVersion == 15, current.revision == expectedRevision {
                        if let retained = try await readArchiveCapture(chatID: target.chatID) {
                            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                            guard retained.expectedRevision == expectedRevision,
                                  try encoder.encode(retained.candidate.archive) == encoder.encode(archive) else {
                                throw TelegramPendingUploadPersistenceError.conflict
                            }
                            candidate = retained.candidate
                        } else {
                            candidate = try TelegramPendingUploadDraft(id: current.id, accountID: accountID, chatID: current.chatID,
                                title: current.title, captionInput: current.captionInput, captionAboveMedia: false, mediaSpoiler: false,
                                originalDraft: current.originalDraft, replyTarget: current.replyTarget,
                                items: current.items, isGrouped: false, presentation: .archive,
                                captionRules: current.captionRules, archive: archive)
                        }
                    } else if current.schemaVersion == 16, current.presentation == .archive {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                        guard try encoder.encode(current.archive) == encoder.encode(archive) else {
                            throw TelegramPendingUploadPersistenceError.conflict
                        }
                        // The native transaction must also match its durable receipt;
                        // matching the descriptor alone never acknowledges a later edit.
                        candidate = current
                    } else { throw TelegramPendingUploadPersistenceError.conflict }
                    guard candidate.isValid else { throw TelegramPendingUploadPersistenceError.incompatibleData }
                    // Reopen every authenticated canonical/raw stream and the ZIP.
                    // This only exports temporary files; it never captures new records.
                    let bundle = try await restoreBundle(draft: candidate)
                    try bundle.discard()
                    try admission.check(accountID: accountID, chatID: target.chatID,
                        preparationID: preparationID, expectedRevision: expectedRevision)
                    if current.schemaVersion == 15 {
                        let _: Void = try await awaitResult { [repository] completion in
                            repository.retainArchiveCapture(candidate, expectedRevision: expectedRevision,
                                admission: admission, completion: completion)
                            return nil
                        }
                        try admission.check(accountID: accountID, chatID: target.chatID,
                            preparationID: preparationID, expectedRevision: expectedRevision)
                    }
                    let _: Void = try await awaitResult { [repository] completion in
                        repository.installArchive(candidate, expectedRevision: expectedRevision,
                            admission: admission, completion: completion)
                        return nil
                    }
                    // Native admission/read/compare/set is the linearization point.
                    // Cancellation after a committed success cannot revoke its ACK.
                    return candidate
                }
            } catch {
                // A refusal delivered from the native queue maps inactive attempts
                // to cancellation. Timeout can still mean a committed, unacknowledged
                // pointer; invalidation only prevents later admission, not rollback.
                try admission.check(accountID: accountID, chatID: target.chatID,
                    preparationID: preparationID, expectedRevision: expectedRevision)
                admission.cancel()
                throw error
            }
        } onCancel: {
            // Generic serial writes intentionally finish after caller cancellation;
            // Archive install additionally carries this native-queue admission token.
            admission.cancel()
        }
    }

    func replaceVideoCover(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                           cover: TelegramUploadVideoCover?) async throws {
        guard target.accountID == accountID, target.hasValidReplySource, file.mode == .video, file.metadata?.gif == nil,
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
            guard target.accountID == accountID, target.hasValidReplySource, file.metadata == nil, (!captionAboveMedia && !mediaSpoiler) || file.mode != .file,
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
        try await prepareBatch(preparationID: preparationID, items: items, isGrouped: isGrouped, presentation: nil,
            target: target, captionInput: captionInput, captionAboveMedia: captionAboveMedia,
            mediaSpoiler: mediaSpoiler, originalDraft: originalDraft)
    }

    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, presentation: TelegramUploadPresentation,
                 target: TelegramUploadTarget, captionInput: TelegramComposerInput, captionAboveMedia: Bool = false,
                 mediaSpoiler: Bool = false, originalDraft: TelegramComposerDraft?) async throws {
        try await prepareBatch(preparationID: preparationID, items: items, isGrouped: isGrouped, presentation: presentation,
            target: target, captionInput: captionInput, captionAboveMedia: captionAboveMedia,
            mediaSpoiler: mediaSpoiler, originalDraft: originalDraft)
    }

    private func prepareBatch(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool,
                              presentation: TelegramUploadPresentation?, target: TelegramUploadTarget,
                              captionInput: TelegramComposerInput, captionAboveMedia: Bool, mediaSpoiler: Bool,
                              originalDraft: TelegramComposerDraft?) async throws {
        let presentation = presentation ?? (items.contains(where: { $0.file.metadata != nil })
            ? (items.allSatisfy { $0.file.mode == .file } ? TelegramUploadPresentation.file : .media) : nil)
        try await serial { [self] in
            guard presentation != .archive, target.accountID == accountID, target.hasValidReplySource, !items.isEmpty,
                  preparationID != TelegramPendingUploadDraft.zeroUUID,
                  Set(items.map(\.id)).count == items.count,
                  items.allSatisfy({ item in item.id != TelegramPendingUploadDraft.zeroUUID &&
                      (presentation != nil || (!captionAboveMedia && !mediaSpoiler) || item.file.mode != .file) &&
                      (presentation == nil || item.file.mode != .photo || item.originalFile != nil) &&
                      (item.file.mode == .video || item.file.videoCover == nil) &&
                      (item.originalFile.map { original in
                          (item.file.mode == .photo || item.file.metadata?.gif != nil) && original.mode == .file && original.video == nil &&
                              original.videoCover == nil && original.metadata == nil && original.size <= 20 * 1024 * 1024
                      } ?? true) }) else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            if let presentation {
                guard presentation != .media || TelegramUploadBatchItem.allowsMedia(items),
                      !isGrouped || presentation.allowsGrouping(items) else { throw TelegramPendingUploadPersistenceError.incompatibleData }
            }
            guard !items.contains(where: { $0.sourceFacts != nil }) || (presentation != nil && items.allSatisfy { $0.sourceFacts != nil }) else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            if items.contains(where: { $0.file.metadata?.voice != nil || $0.file.metadata?.roundVideo != nil }) {
                _ = try TelegramUploadBatchPlan(items: items, isGrouped: isGrouped, caption: captionInput.formattedText,
                    captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler, presentation: presentation)
            }
            let previous = try await read(chatID: target.chatID)
            if let previous, previous.id == preparationID {
                guard (presentation == nil ? [6, 7].contains(previous.schemaVersion)
                        : previous.schemaVersion >= 8 && previous.presentation == presentation),
                      previous.disposition == .prepared,
                      previous.originalDraft == originalDraft, previous.isGrouped == isGrouped,
                      previous.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)),
                      previous.items.count == items.count,
                      zip(previous.items, items).allSatisfy({ stored, staged in
                          stored.id == staged.id && stored.file.attachment.name.utf8.elementsEqual(staged.file.name.utf8) &&
                          stored.file.plaintextByteCount == staged.file.size && stored.file.attachment.kind == staged.file.mode.rawValue &&
                          stored.video == staged.file.video && telegramPendingUploadCoverMatches(stored.videoCover, staged.file.videoCover) &&
                          stored.metadata == staged.file.metadata && stored.sourceFacts == staged.sourceFacts &&
                          stored.matchesOriginal(staged.originalFile)
                      }) else { throw TelegramPendingUploadPersistenceError.conflict }
                let storage = try files()
                for (stored, staged) in zip(previous.items, items) {
                    guard try await storage.matches(file: staged.file, record: stored.file) else {
                        throw TelegramPendingUploadPersistenceError.conflict
                    }
                    if let original = staged.originalFile, let record = stored.originalFile {
                        guard try await storage.matches(file: original, record: record) else {
                            throw TelegramPendingUploadPersistenceError.conflict
                        }
                    }
                }
                for item in items { try await item.verifySourceFacts() }
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
            for item in items { try await item.verifySourceFacts() }
            let captures = try items.map { try TelegramPendingUploadFiles.captureFile($0.file) }
            let covers = try items.map { try $0.file.videoCover.map(TelegramPendingUploadFiles.captureCover) }
            let originals = try items.map { try $0.originalFile.map(TelegramPendingUploadFiles.captureFile) }
            for (index, item) in items.enumerated() {
                try await item.verifyGIFPair()
                if let facts = item.sourceFacts {
                    let capture = facts.role == .original ? originals[index] : captures[index]
                    guard let capture, try capture.plaintextSHA256() == facts.plaintextSHA256 else {
                        throw TelegramPendingUploadPersistenceError.incompatibleData
                    }
                }
            }
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
                let original: ArchiveFileRecord?
                if let staged = item.originalFile, let capture = originals[index] {
                    original = try await storage.saveOriginal(staged, accountID: accountID, chatID: target.chatID,
                        preparationID: preparationID, itemID: item.id, capture: capture)
                } else { original = nil }
                stored.append(.init(id: item.id, file: record, video: item.file.video, videoCover: cover, originalFile: original,
                    metadata: item.file.metadata, sourceFacts: item.sourceFacts))
            }
            let draft = try TelegramPendingUploadDraft(id: preparationID, accountID: accountID, chatID: target.chatID,
                title: target.title, captionInput: captionInput, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler,
                originalDraft: originalDraft, replyTarget: target.replySource.map(TelegramComposerReplyTarget.init(source:)),
                items: stored, isGrouped: isGrouped, presentation: presentation)
            try await write(draft, expectedRevision: previous?.revision)
        }
    }

    /// Select only resources already archived by this preparation. This never
    /// uploads a replacement and preserves current caption/cover edits.
    func updatePresentation(preparationID: UUID, orderedIDs: [UUID], previousPresentation: TelegramUploadPresentation,
                            previousGrouping: Bool, presentation: TelegramUploadPresentation, isGrouped: Bool,
                            target: TelegramUploadTarget) async throws {
        guard target.accountID == accountID, target.hasValidReplySource, !orderedIDs.isEmpty,
              Set(orderedIDs).count == orderedIDs.count else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        try await serial { [self] in
            guard let current = try await read(chatID: target.chatID), current.id == preparationID,
                  (6...16).contains(current.schemaVersion), current.disposition == .prepared,
                  current.items.map(\.id) == orderedIDs,
                  current.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            if current.schemaVersion >= 8, current.presentation == presentation, current.isGrouped == isGrouped { return }
            guard current.presentation == previousPresentation, current.isGrouped == previousGrouping else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            guard presentation != .media || TelegramPendingUploadItem.allowsMedia(current.items) else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            if presentation == .archive, current.archive == nil {
                guard current.schemaVersion == 15, !isGrouped else {
                    throw TelegramPendingUploadPersistenceError.incompatibleData
                }
                let captured = try await archiveCandidate(current), candidate = captured.candidate
                let admission = TelegramPendingUploadArchiveAdmission(accountID: accountID, chatID: target.chatID,
                    preparationID: preparationID, expectedRevision: current.revision, generation: UUID(),
                    archiveIntentRecordID: captured.intentRecordID)
                defer { admission.cancel() }
                let _: Void = try await awaitResult { [repository] completion in
                    repository.retainArchiveCapture(candidate, expectedRevision: current.revision,
                        admission: admission, completion: completion)
                    return nil
                }
                let _: Void = try await awaitResult { [repository] completion in
                    repository.installArchive(candidate, expectedRevision: current.revision,
                        admission: admission, completion: completion)
                    return nil
                }
                return
            }
            if presentation == .archive {
                let authenticated = try await restoreBundle(draft: current)
                try authenticated.discard()
            }
            let updated = try TelegramPendingUploadDraft(id: current.id, accountID: current.accountID, chatID: current.chatID,
                title: current.title, captionInput: current.captionInput,
                captionAboveMedia: presentation == .archive ? false : current.captionAboveMedia,
                mediaSpoiler: presentation == .archive ? false : current.mediaSpoiler,
                originalDraft: current.originalDraft, replyTarget: current.replyTarget,
                items: current.items, isGrouped: isGrouped, presentation: presentation,
                captionRules: current.captionRules, archive: current.archive)
            try await write(updated, expectedRevision: current.revision)
        }
    }

    /// Reserves capture identities before storage; retries authenticate the exact
    /// immutable object even if native candidate retention never committed.
    private func archiveCandidate(_ current: TelegramPendingUploadDraft) async throws
        -> (candidate: TelegramPendingUploadDraft, intentRecordID: UUID?) {
        guard current.schemaVersion == 15, current.items.count > 1,
              current.items.count <= TelegramUploadArchiveLimits.members else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        var intent: TelegramPendingUploadArchiveIntent? = try await awaitResult { [repository] completion in
            repository.loadArchiveIntent(chatID: current.chatID, completion: completion)
        }
        if let retained = try await readArchiveCapture(chatID: current.chatID) {
            let authenticated = try await restoreBundle(draft: retained.candidate)
            try authenticated.discard()
            return (retained.candidate, intent?.recordID)
        }
        let storage = try files()
        if let intent, let record = try await storage.recoverArchive(intent, accountID: accountID, chatID: current.chatID) {
            let candidate = try intent.candidate(current: current, record: record)
            let authenticated = try await restoreBundle(draft: candidate)
            try authenticated.discard()
            return (candidate, intent.recordID)
        }
        let originals = try await restoreBundle(draft: current)
        var zip: TelegramUploadArchiveIO.Archive?
        do {
            let sources = originals.items.map { TelegramUploadArchiveIO.Source(itemID: $0.id, file: $0.rawSource) }
            let created = try await TelegramUploadArchiveIO.prepare(sources)
            zip = created
            let capture = try TelegramPendingUploadFiles.captureArchive(created.file)
            let digest = try capture.plaintextSHA256()
            let members = created.members.map { TelegramPendingUploadArchive.Member(itemID: $0.itemID, entryName: $0.entryName) }
            if intent == nil {
                let reserved = TelegramPendingUploadArchiveIntent(preparationID: current.id, expectedRevision: current.revision,
                    archiveID: created.file.id, recordID: UUID(), candidateRevision: UUID(), byteCount: created.file.size,
                    plaintextSHA256: digest, members: members)
                let admission = TelegramPendingUploadArchiveAdmission(accountID: accountID, chatID: current.chatID,
                    preparationID: current.id, expectedRevision: current.revision, generation: UUID())
                defer { admission.cancel() }
                let _: Void = try await awaitResult { [repository] completion in
                    repository.retainArchiveIntent(reserved, chatID: current.chatID, admission: admission, completion: completion)
                    return nil
                }
                intent = reserved
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let intent, intent.isValid(for: current), intent.byteCount == created.file.size,
                  intent.plaintextSHA256 == digest, try encoder.encode(intent.members) == encoder.encode(members) else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            let record = try await storage.saveArchive(created, sources: sources, archiveID: intent.archiveID,
                accountID: accountID, chatID: current.chatID, preparationID: current.id, capture: capture, reservedID: intent.recordID)
            let candidate = try intent.candidate(current: current, record: record)
            let authenticated = try await restoreBundle(draft: candidate)
            try authenticated.discard()
            try originals.discard(); try TelegramUploadFileIO.discard(created.file)
            return (candidate, intent.recordID)
        } catch {
            try? originals.discard()
            if let zip { try? TelegramUploadFileIO.discard(zip.file) }
            throw error
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

    /// Reorder/remove only the originals already admitted by this preparation.
    /// The old order guards stale actions; an exact new order permits lost-ACK retry.
    func updateItems(preparationID: UUID, previousIDs: [UUID], previousGrouping: Bool, orderedIDs: [UUID],
                     isGrouped: Bool, target: TelegramUploadTarget) async throws {
        try await updateStoredItems(preparationID: preparationID, previousIDs: previousIDs, previousGrouping: previousGrouping,
            previousPresentation: nil, orderedIDs: orderedIDs, isGrouped: isGrouped, presentation: nil, target: target)
    }

    func updateItems(preparationID: UUID, previousIDs: [UUID], previousGrouping: Bool,
                     previousPresentation: TelegramUploadPresentation, orderedIDs: [UUID], isGrouped: Bool,
                     presentation: TelegramUploadPresentation, target: TelegramUploadTarget) async throws {
        try await updateStoredItems(preparationID: preparationID, previousIDs: previousIDs, previousGrouping: previousGrouping,
            previousPresentation: previousPresentation, orderedIDs: orderedIDs, isGrouped: isGrouped,
            presentation: presentation, target: target)
    }

    private func updateStoredItems(preparationID: UUID, previousIDs: [UUID], previousGrouping: Bool,
                                   previousPresentation: TelegramUploadPresentation?, orderedIDs: [UUID], isGrouped: Bool,
                                   presentation: TelegramUploadPresentation?, target: TelegramUploadTarget) async throws {
        guard target.accountID == accountID, target.hasValidReplySource, !orderedIDs.isEmpty,
              Set(previousIDs).count == previousIDs.count, Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs).isSubset(of: Set(previousIDs)) else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        try await serial { [self] in
            guard let current = try await read(chatID: target.chatID), current.id == preparationID,
                  (6...16).contains(current.schemaVersion), current.disposition == .prepared,
                  current.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)) else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            let currentIDs = current.items.map(\.id)
            let lookup = Dictionary(uniqueKeysWithValues: current.items.map { ($0.id, $0) })
            let ordered = orderedIDs.compactMap { lookup[$0] }
            guard ordered.count == orderedIDs.count else { throw TelegramPendingUploadPersistenceError.conflict }
            let oldPresentation = previousPresentation ?? current.presentation
            let normalized: TelegramUploadPresentation = oldPresentation == .media &&
                !TelegramPendingUploadItem.allowsMedia(ordered) ? .file : oldPresentation
            guard presentation == nil || presentation == normalized else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            if currentIDs == orderedIDs, current.isGrouped == isGrouped, current.presentation == normalized { return }
            guard currentIDs == previousIDs, current.isGrouped == previousGrouping, current.presentation == oldPresentation else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            guard normalized != .archive else { throw TelegramPendingUploadPersistenceError.incompatibleData }
            let updated = try TelegramPendingUploadDraft(id: current.id, accountID: current.accountID, chatID: current.chatID,
                title: current.title, captionInput: current.captionInput, captionAboveMedia: current.captionAboveMedia,
                mediaSpoiler: current.mediaSpoiler, originalDraft: current.originalDraft, replyTarget: current.replyTarget,
                items: ordered, isGrouped: isGrouped, presentation: current.schemaVersion >= 8 ? normalized : nil,
                captionRules: current.captionRules, archive: currentIDs == orderedIDs ? current.archive : nil)
            try await write(updated, expectedRevision: current.revision)
        }
    }

    func replaceVideoCover(preparationID: UUID, itemID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget,
                           cover: TelegramUploadVideoCover?) async throws {
        guard target.accountID == accountID, target.hasValidReplySource, file.mode == .video,
              file.metadata?.roundVideo == nil,
              file.video?.isValid(name: file.name, size: file.size) == true else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        let capture = try cover.map(TelegramPendingUploadFiles.captureCover)
        try await serial { [self] in
            guard let current = try await read(chatID: target.chatID), current.id == preparationID,
                  (6...16).contains(current.schemaVersion), current.disposition == .prepared, current.presentation != .archive,
                  current.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)),
                  let index = current.items.firstIndex(where: { $0.id == itemID }) else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            let item = current.items[index]
            guard item.metadata?.roundVideo == nil else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            guard item.file.attachment.kind == "video", item.file.attachment.name.utf8.elementsEqual(file.name.utf8),
                  item.file.plaintextByteCount == file.size, item.video == file.video else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            if telegramPendingUploadCoverMatches(item.videoCover, cover) { return }
            guard telegramPendingUploadCoverMatches(item.videoCover, file.videoCover) else {
                throw TelegramPendingUploadPersistenceError.conflict
            }
            let saved: TelegramPendingUploadVideoCover?
            if let cover, let capture {
                saved = try await files().saveCover(cover, accountID: accountID, chatID: target.chatID,
                    preparationID: preparationID, itemID: itemID, capture: capture)
            } else { saved = nil }
            var items = current.items
            items[index] = .init(id: item.id, file: item.file, video: item.video, videoCover: saved, originalFile: item.originalFile,
                metadata: item.metadata, sourceFacts: item.sourceFacts)
            let updated = try TelegramPendingUploadDraft(id: current.id, accountID: current.accountID, chatID: current.chatID,
                title: current.title, captionInput: current.captionInput, captionAboveMedia: current.captionAboveMedia,
                mediaSpoiler: current.mediaSpoiler, originalDraft: current.originalDraft, replyTarget: current.replyTarget,
                items: items, isGrouped: current.isGrouped, presentation: current.schemaVersion >= 8 ? current.presentation : nil,
                captionRules: current.captionRules, archive: current.archive)
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
        guard draft.isValid, draft.accountID == accountID, draft.archive == nil else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        let storage = try files()
        return try await restoreCanonicalItems(draft: draft, storage: storage)
    }

    func restoreBundle(draft: TelegramPendingUploadDraft) async throws -> TelegramRecoveredUploadBundle {
        try Task.checkCancellation()
        guard draft.isValid, draft.accountID == accountID else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        let storage = try files()
        let restored = try await restoreCanonicalItems(draft: draft, storage: storage)
        var archiveFile: TelegramUploadFile?
        do {
            let archive: TelegramUploadArchiveIO.Archive?
            if let descriptor = draft.archive {
                let file = try await storage.restoreArchive(record: descriptor.file, archiveID: descriptor.id,
                    accountID: accountID, chatID: draft.chatID, preparationID: draft.id)
                archiveFile = file
                let members = try zip(descriptor.members, draft.items).map { member, item in
                    guard let facts = item.sourceFacts else { throw TelegramPendingUploadPersistenceError.incompatibleData }
                    return TelegramUploadArchiveIO.Member(itemID: member.itemID, sourceName: facts.name,
                        entryName: member.entryName, byteCount: facts.byteCount, plaintextSHA256: facts.plaintextSHA256)
                }
                let complete = TelegramUploadArchiveIO.Archive(file: file, members: members)
                try await TelegramUploadArchiveValidation.validate(complete,
                    sources: restored.map { .init(itemID: $0.id, file: $0.rawSource) },
                    expectedPlaintextSHA256: descriptor.file.plaintextSHA256)
                archive = complete
            } else { archive = nil }
            try Task.checkCancellation()
            return .init(items: restored, archive: archive)
        } catch {
            restored.forEach { try? $0.discard() }
            if let archiveFile { try? TelegramUploadFileIO.discard(archiveFile) }
            throw error
        }
    }

    private func restoreCanonicalItems(draft: TelegramPendingUploadDraft,
                                       storage: TelegramPendingUploadFiles) async throws -> [TelegramUploadBatchItem] {
        var restored: [TelegramUploadBatchItem] = []
        do {
            for item in draft.items {
                let itemID = draft.schemaVersion >= 6 ? item.id : nil
                let file = try await storage.restore(record: item.file, accountID: accountID,
                    chatID: draft.chatID, preparationID: draft.id, video: item.video, itemID: itemID, metadata: item.metadata)
                // Register each stage before cover export so every failure cleans it.
                restored.append(.init(id: item.id, file: file, sourceFacts: item.sourceFacts))
                if let saved = item.originalFile {
                    let original = try await storage.restoreOriginal(saved, accountID: accountID, chatID: draft.chatID,
                        preparationID: draft.id, itemID: item.id)
                    restored[restored.count - 1] = .init(id: item.id, file: file, originalFile: original, sourceFacts: item.sourceFacts)
                }
                try await restored[restored.count - 1].verifyGIFPair()
                try await restored[restored.count - 1].verifySourceFacts()
                if let saved = item.videoCover {
                    let cover = try await storage.restoreCover(saved, accountID: accountID, chatID: draft.chatID,
                        preparationID: draft.id, itemID: itemID)
                    restored[restored.count - 1] = .init(id: item.id, file: TelegramUploadFile(id: file.id, name: file.name,
                        size: file.size, mode: file.mode, pixelWidth: file.pixelWidth, pixelHeight: file.pixelHeight,
                        url: file.url, directory: file.directory, video: file.video, videoCover: cover, metadata: file.metadata),
                        originalFile: restored[restored.count - 1].originalFile, sourceFacts: item.sourceFacts)
                }
            }
            return restored
        } catch {
            for item in restored { try? item.discard() }
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

    private func readArchiveCapture(chatID: Int64) async throws -> TelegramPendingUploadArchiveCapture? {
        try await awaitResult { [repository] completion in
            repository.loadArchiveCapture(chatID: chatID, completion: completion)
        }
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
