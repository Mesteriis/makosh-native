import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

enum TelegramUploadBatchEvent: Equatable {
    case committing, accepted([TelegramUploadQueueID]), progress(Double?), queueFailed, rejected, uncertain
}

@MainActor protocol TelegramUploadBatchProvider: TelegramUploadProvider {
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease
    func submit(bundle: TelegramRecoveredUploadBundle, draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease
}

extension TelegramUploadBatchProvider {
    // Legacy adapters can submit ordinary items; an Archive requires explicit bundle support.
    func submit(bundle: TelegramRecoveredUploadBundle, draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        guard bundle.archive == nil, draft.archive == nil else {
            receive(.rejected); return TelegramRejectedBatchUploadLease()
        }
        return submit(items: bundle.items, draft: draft, target: target, receive: receive)
    }
}

@MainActor private final class TelegramRejectedBatchUploadLease: TelegramUploadLease {
    func stop() {}
}

enum TelegramUploadBatchAdmission {
    case rejected, uncertain, accepted([MessageId])
}

/// Shared by the Account provider and isolated native-queue QA. Resource copies
/// finish as a whole before the single Postbox admission/receipt transaction.
@MainActor final class TelegramUploadBatchSubmission: TelegramUploadLease {
    private let postbox: Postbox
    private let items: [TelegramUploadBatchItem]
    private let archive: TelegramUploadArchiveIO.Archive?
    private let draft: TelegramPendingUploadDraft
    private let target: TelegramUploadTarget
    private let enqueue: (TelegramUploadBatchEnqueueReceipt, [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError>
    private let observe: (([MessageId]) -> Signal<TelegramUploadBatchEvent, NoError>)?
    private let receive: @MainActor (TelegramUploadBatchEvent) -> Void
    private var preparations: [TelegramUploadMediaBoxPreparation] = []
    private var resources: [TelegramUploadBatchResource] = []
    private let operation = MetaDisposable(), observation = MetaDisposable()
    private var validation: Task<Void, Never>?
    private var stopped = false, committing = false, accepted = false

    convenience init(postbox: Postbox, accountID: Int64, bundle: TelegramRecoveredUploadBundle, draft: TelegramPendingUploadDraft,
         target: TelegramUploadTarget,
         enqueue: @escaping (TelegramUploadBatchEnqueueReceipt, [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError>,
         observe: (([MessageId]) -> Signal<TelegramUploadBatchEvent, NoError>)? = nil,
         receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) {
        self.init(postbox: postbox, accountID: accountID, items: bundle.items, archive: bundle.archive, draft: draft, target: target,
            enqueue: enqueue, observe: observe, receive: receive)
    }

    convenience init(postbox: Postbox, accountID: Int64, items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft,
         target: TelegramUploadTarget,
         enqueue: @escaping (TelegramUploadBatchEnqueueReceipt, [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError>,
         observe: (([MessageId]) -> Signal<TelegramUploadBatchEvent, NoError>)? = nil,
         receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) {
        self.init(postbox: postbox, accountID: accountID, items: items, archive: nil, draft: draft, target: target,
            enqueue: enqueue, observe: observe, receive: receive)
    }

    private init(postbox: Postbox, accountID: Int64, items: [TelegramUploadBatchItem], archive: TelegramUploadArchiveIO.Archive?, draft: TelegramPendingUploadDraft,
         target: TelegramUploadTarget,
         enqueue: @escaping (TelegramUploadBatchEnqueueReceipt, [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError>,
         observe: (([MessageId]) -> Signal<TelegramUploadBatchEvent, NoError>)? = nil,
         receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) {
        self.postbox = postbox
        self.archive = archive
        if let archive, let descriptor = draft.archive {
            self.items = [.init(id: descriptor.id, file: archive.file)]
        } else {
            self.items = draft.schemaVersion >= 8 ? items.compactMap { $0.presented(as: draft.presentation) } : items
        }
        self.draft = draft; self.target = target
        self.enqueue = enqueue; self.observe = observe; self.receive = receive
        guard accountID == target.accountID, draft.accountID == accountID, target.chatID == draft.chatID,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(PeerId(target.chatID).namespace),
              target.hasValidReplySource, draft.isValid, draft.disposition == .submissionStarted,
              draft.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)),
              items.count == draft.items.count,
              zip(items, draft.items).allSatisfy({ $0.id == $1.id && $0.file.metadata == $1.metadata &&
                  $0.sourceFacts == $1.sourceFacts && $1.matchesOriginal($0.originalFile) }) else {
            finish(.rejected); return
        }
        if let archive {
            guard draft.schemaVersion == 16, draft.presentation == .archive, let descriptor = draft.archive,
                  archive.file.name.utf8.elementsEqual(descriptor.file.attachment.name.utf8),
                  archive.file.size == descriptor.file.plaintextByteCount,
                  archive.members.count == descriptor.members.count,
                  zip(archive.members, descriptor.members).allSatisfy({
                      $0.itemID == $1.itemID && $0.entryName.utf8.elementsEqual($1.entryName.utf8)
                  }),
                  zip(archive.members, draft.items).allSatisfy({ member, item in
                      guard let facts = item.sourceFacts else { return false }
                      return member.itemID == item.id && member.sourceName.utf8.elementsEqual(facts.name.utf8) &&
                          member.byteCount == facts.byteCount && member.plaintextSHA256 == facts.plaintextSHA256
                  }),
                  (try? TelegramUploadBatchPlan(archiveID: descriptor.id, caption: draft.captionInput.formattedText)) != nil else {
                finish(.rejected); return
            }
            validation = Task { [weak self] in
                do {
                    try await Self.validateArchive(archive, canonical: items, draft: draft)
                    try Task.checkCancellation()
                    guard let self, !self.stopped else { return }
                    self.prepareNext()
                } catch {
                    guard let self, !self.stopped, !Task.isCancelled else { return }
                    self.finish(.rejected)
                }
            }
            return
        }
        guard draft.archive == nil, [6, 7, 8, 9, 10, 11, 12, 13, 14, 15].contains(draft.schemaVersion),
              self.items.count == items.count,
              (try? TelegramUploadBatchPlan(items: self.items, isGrouped: draft.isGrouped, caption: draft.captionInput.formattedText,
                captionAboveMedia: draft.captionAboveMedia, mediaSpoiler: draft.mediaSpoiler,
                presentation: draft.schemaVersion >= 8 ? draft.presentation : nil, captionRules: draft.captionRules)) != nil else {
            finish(.rejected); return
        }
        prepareNext()
    }

    private static func validateArchive(_ archive: TelegramUploadArchiveIO.Archive,
                                        canonical: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft) async throws {
        for (item, saved) in zip(canonical, draft.items) {
            try Task.checkCancellation()
            guard saved.file.attachment.name.utf8.elementsEqual(item.file.name.utf8),
                  saved.file.attachment.kind == item.file.mode.rawValue, saved.file.plaintextByteCount == item.file.size,
                  saved.video == item.file.video, telegramPendingUploadCoverMatches(saved.videoCover, item.file.videoCover) else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            let capture = try TelegramPendingUploadFiles.captureFile(item.file)
            let cover = try item.file.videoCover.map(TelegramPendingUploadFiles.captureCover)
            let matches = try await Task.detached(priority: .utility) {
                try capture.plaintextSHA256() == saved.file.plaintextSHA256 &&
                    (cover == nil || cover?.plaintextSHA256() == saved.videoCover?.file.plaintextSHA256)
            }.value
            guard matches else { throw TelegramUploadFileError.unavailable }
            try await TelegramUploadFileIO.verifyMetadata(item.file)
            try await item.verifyGIFPair()
            try await item.verifySourceFacts()
        }
        try await TelegramUploadArchiveValidation.validate(archive,
            sources: canonical.map { .init(itemID: $0.id, file: $0.rawSource) },
            expectedPlaintextSHA256: draft.archive?.file.plaintextSHA256)
    }

    private func prepareNext() {
        guard !stopped, !committing else { return }
        let index = resources.count
        guard index < items.count else { commit(); return }
        let item = items[index]
        guard let record = archive != nil ? draft.archive?.file : draft.schemaVersion >= 8 ? draft.items[index].payload(for: draft.presentation) : draft.items[index].file else {
            finish(.rejected); return
        }
        let digest = record.plaintextSHA256
        let preparation = TelegramUploadMediaBoxPreparation(mediaBox: postbox.mediaBox, file: item.file, originalFile: item.originalFile,
            expectedPlaintextSHA256: digest, sourceFacts: item.sourceFacts) { [weak self] result in
                guard let self, !self.stopped, !self.committing, self.resources.count == index else { return }
                guard case let .success(prepared) = result else { self.finish(.rejected); return }
                self.resources.append(.init(item: item, plaintextSHA256: digest, prepared: prepared))
                self.prepareNext()
            }
        preparations.append(preparation)
    }

    private func commit() {
        guard !stopped, !committing else { return }
        do {
            let plan = try archive != nil ? TelegramUploadBatchPlan(archiveID: items[0].id, caption: draft.captionInput.formattedText)
                : TelegramUploadBatchPlan(items: items, isGrouped: draft.isGrouped,
                caption: draft.captionInput.formattedText, captionAboveMedia: draft.captionAboveMedia, mediaSpoiler: draft.mediaSpoiler,
                presentation: draft.schemaVersion >= 8 ? draft.presentation : nil, captionRules: draft.captionRules)
            var keys: [Int64] = []
            while keys.count < plan.groupCount {
                let key = Int64.random(in: Int64.min...Int64.max)
                if !keys.contains(key) { keys.append(key) }
            }
            let receipt = try TelegramUploadBatchEnqueueReceipt(draft: draft, target: target, resources: resources, groupKeys: keys)
            guard let messages = receipt.messages(replySource: target.replySource) else { finish(.rejected); return }
            committing = true; receive(.committing)
            guard !stopped else { return }
            operation.set((enqueue(receipt, messages) |> deliverOnMainQueue).start(next: { [weak self] admission in
                guard let self, !self.stopped, !self.accepted else { return }
                switch admission {
                case .rejected: self.finish(.rejected)
                case .uncertain: self.finish(.uncertain)
                case let .accepted(ids):
                    self.accepted = true; self.receive(.accepted(ids.map(TelegramUploadQueueID.init)))
                    guard !self.stopped, let observe = self.observe else { return }
                    self.observation.set((observe(ids) |> deliverOnMainQueue).start(next: { [weak self] event in
                        guard let self, !self.stopped else { return }
                        // Observation never manufactures another acceptance.
                        switch event {
                        case .progress, .queueFailed: self.receive(event)
                        default: break
                        }
                    }))
                }
            }))
        } catch { finish(.rejected) }
    }

    private func finish(_ event: TelegramUploadBatchEvent) {
        guard !stopped else { return }
        receive(event); stop()
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; validation?.cancel(); validation = nil; operation.dispose(); observation.dispose()
        preparations.forEach { $0.stop() }; preparations.removeAll()
        // Disposing an observation does not recall a committed native send.
    }
    isolated deinit { stop() }
}

/// Keep the exact same receipt hooks for Account enqueue and local native QA.
nonisolated func telegramUploadBatchEnqueue(
    receipt: TelegramUploadBatchEnqueueReceipt, messages: [EnqueueMessage],
    now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
    enqueue: ([EnqueueMessage], @escaping (Transaction) -> Bool, @escaping (Transaction, [MessageId?]) -> Void) -> Signal<[MessageId?], NoError>
) -> Signal<TelegramUploadBatchAdmission, NoError> {
    let saved = Atomic<Bool>(value: false)
    return enqueue(messages, { receipt.validateAdmission(transaction: $0, timestamp: now()) }, { transaction, ids in
        _ = saved.swap(receipt.acknowledge(transaction: transaction, messageIDs: ids))
    }) |> map { ids in
        guard !ids.isEmpty else { return .rejected }
        let complete = ids.compactMap { $0 }
        guard complete.count == receipt.plan.messages.count, saved.with({ $0 }) else { return .uncertain }
        return .accepted(complete)
    }
}
