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
}

enum TelegramUploadBatchAdmission {
    case rejected, uncertain, accepted([MessageId])
}

/// Shared by the Account provider and isolated native-queue QA. Resource copies
/// finish as a whole before the single Postbox admission/receipt transaction.
@MainActor final class TelegramUploadBatchSubmission: TelegramUploadLease {
    private let postbox: Postbox
    private let items: [TelegramUploadBatchItem]
    private let draft: TelegramPendingUploadDraft
    private let target: TelegramUploadTarget
    private let enqueue: (TelegramUploadBatchEnqueueReceipt, [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError>
    private let observe: (([MessageId]) -> Signal<TelegramUploadBatchEvent, NoError>)?
    private let receive: @MainActor (TelegramUploadBatchEvent) -> Void
    private var preparations: [TelegramUploadMediaBoxPreparation] = []
    private var resources: [TelegramUploadBatchResource] = []
    private let operation = MetaDisposable(), observation = MetaDisposable()
    private var stopped = false, committing = false, accepted = false

    init(postbox: Postbox, accountID: Int64, items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft,
         target: TelegramUploadTarget,
         enqueue: @escaping (TelegramUploadBatchEnqueueReceipt, [EnqueueMessage]) -> Signal<TelegramUploadBatchAdmission, NoError>,
         observe: (([MessageId]) -> Signal<TelegramUploadBatchEvent, NoError>)? = nil,
         receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) {
        self.postbox = postbox
        self.items = draft.schemaVersion == 8 ? items.compactMap { $0.presented(as: draft.presentation) } : items
        self.draft = draft; self.target = target
        self.enqueue = enqueue; self.observe = observe; self.receive = receive
        guard accountID == target.accountID, draft.accountID == accountID, target.chatID == draft.chatID,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(PeerId(target.chatID).namespace),
              target.hasValidReplySource, draft.isValid, [6, 7, 8].contains(draft.schemaVersion), draft.disposition == .submissionStarted,
              items.count == draft.items.count, self.items.count == items.count,
              zip(items, draft.items).allSatisfy({ $0.id == $1.id && $1.matchesOriginal($0.originalFile) }),
              (try? TelegramUploadBatchPlan(items: self.items, isGrouped: draft.isGrouped, caption: draft.captionInput.formattedText,
                captionAboveMedia: draft.captionAboveMedia, mediaSpoiler: draft.mediaSpoiler,
                presentation: draft.schemaVersion == 8 ? draft.presentation : nil)) != nil else {
            finish(.rejected); return
        }
        prepareNext()
    }

    private func prepareNext() {
        guard !stopped, !committing else { return }
        let index = resources.count
        guard index < items.count else { commit(); return }
        let item = items[index]
        guard let record = draft.schemaVersion == 8 ? draft.items[index].payload(for: draft.presentation) : draft.items[index].file else {
            finish(.rejected); return
        }
        let digest = record.plaintextSHA256
        let preparation = TelegramUploadMediaBoxPreparation(mediaBox: postbox.mediaBox, file: item.file,
            expectedPlaintextSHA256: digest) { [weak self] result in
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
            let plan = try TelegramUploadBatchPlan(items: items, isGrouped: draft.isGrouped,
                caption: draft.captionInput.formattedText, captionAboveMedia: draft.captionAboveMedia, mediaSpoiler: draft.mediaSpoiler,
                presentation: draft.schemaVersion == 8 ? draft.presentation : nil)
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
        stopped = true; operation.dispose(); observation.dispose()
        preparations.forEach { $0.stop() }; preparations.removeAll()
        // Disposing an observation does not recall a committed native send.
    }
    isolated deinit { stop() }
}

/// Keep the exact same receipt hooks for Account enqueue and local native QA.
nonisolated func telegramUploadBatchEnqueue(
    receipt: TelegramUploadBatchEnqueueReceipt, messages: [EnqueueMessage],
    enqueue: ([EnqueueMessage], @escaping (Transaction) -> Bool, @escaping (Transaction, [MessageId?]) -> Void) -> Signal<[MessageId?], NoError>
) -> Signal<TelegramUploadBatchAdmission, NoError> {
    let saved = Atomic<Bool>(value: false)
    return enqueue(messages, { receipt.validate(transaction: $0) }, { transaction, ids in
        _ = saved.swap(receipt.acknowledge(transaction: transaction, messageIDs: ids))
    }) |> map { ids in
        guard !ids.isEmpty else { return .rejected }
        let complete = ids.compactMap { $0 }
        guard complete.count == receipt.plan.messages.count, saved.with({ $0 }) else { return .uncertain }
        return .accepted(complete)
    }
}
