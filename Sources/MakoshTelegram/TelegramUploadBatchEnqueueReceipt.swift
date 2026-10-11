import Foundation
import Postbox
import TelegramCore

struct TelegramUploadBatchResource: Sendable {
    let item: TelegramUploadBatchItem
    let plaintextSHA256: String
    let resourceID: Int64
    let videoThumbnail: TelegramUploadVideoThumbnailResource?
    let videoCover: TelegramUploadVideoThumbnailResource?
    let webPPreview: TelegramUploadVideoThumbnailResource?
    let gifPreview: TelegramUploadVideoThumbnailResource?
    init(item: TelegramUploadBatchItem, plaintextSHA256: String, prepared: TelegramPreparedUploadMedia) {
        self.item = item; self.plaintextSHA256 = plaintextSHA256; resourceID = prepared.resource.fileId
        videoThumbnail = prepared.videoThumbnail; videoCover = prepared.videoCover
        webPPreview = prepared.webPPreview
        gifPreview = prepared.gifPreview
    }
    var reference: AnyMediaReference? {
        telegramUploadMedia(item.file, videoThumbnail: videoThumbnail, videoCover: videoCover,
            webPPreview: webPPreview, gifPreview: gifPreview, resourceID: resourceID)?.1
    }
}

/// One immutable capability for the full native queue transaction, including a
/// separate leading text message when the reference workflow requires it.
struct TelegramUploadBatchEnqueueReceipt: Sendable {
    let draft: TelegramPendingUploadDraft
    let target: TelegramUploadTarget
    let resources: [TelegramUploadBatchResource]
    let plan: TelegramUploadBatchPlan
    let groupKeys: [Int64]
    private let encodedDraft: Data

    init(draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
         resources: [TelegramUploadBatchResource], groupKeys: [Int64]) throws {
        guard draft.isValid, [6, 7, 8, 9, 10, 11, 12].contains(draft.schemaVersion), draft.disposition == .submissionStarted,
              [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(PeerId(target.chatID).namespace),
              target.hasValidReplySource, target.accountID == draft.accountID, target.chatID == draft.chatID,
              draft.replyTarget == target.replySource.map(TelegramComposerReplyTarget.init(source:)),
              resources.count == draft.items.count else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        let plan = try TelegramUploadBatchPlan(items: resources.map(\.item), isGrouped: draft.isGrouped,
            caption: draft.captionInput.formattedText, captionAboveMedia: draft.captionAboveMedia, mediaSpoiler: draft.mediaSpoiler,
            presentation: draft.schemaVersion >= 8 ? draft.presentation : nil)
        guard groupKeys.count == plan.groupCount, Set(groupKeys).count == groupKeys.count else {
            throw TelegramPendingUploadPersistenceError.incompatibleData
        }
        var ids: [Int64] = []
        for (stored, resource) in zip(draft.items, resources) {
            let file = resource.item.file
            let filePresentation = draft.schemaVersion >= 8 && draft.presentation == .file
            guard let payload = filePresentation ? stored.payload(for: .file) : stored.file,
                  stored.id == resource.item.id, payload.attachment.name.utf8.elementsEqual(file.name.utf8),
                  (filePresentation ? "file" : payload.attachment.kind) == file.mode.rawValue, payload.plaintextByteCount == file.size,
                  payload.plaintextSHA256 == resource.plaintextSHA256, (filePresentation ? nil : stored.video) == file.video,
                  stored.metadata == file.metadata,
                  telegramPendingUploadCoverMatches(filePresentation ? nil : stored.videoCover, file.videoCover),
                  stored.matchesOriginal(resource.item.originalFile), resource.reference != nil else {
                throw TelegramPendingUploadPersistenceError.incompatibleData
            }
            ids.append(resource.resourceID)
            if let thumbnail = resource.videoThumbnail { ids.append(thumbnail.id) }
            if let cover = resource.videoCover { ids.append(cover.id) }
            if let preview = resource.webPPreview { ids.append(preview.id) }
            if let preview = resource.gifPreview { ids.append(preview.id) }
        }
        guard Set(ids).count == ids.count else { throw TelegramPendingUploadPersistenceError.incompatibleData }
        self.draft = draft; self.target = target; self.resources = resources; self.plan = plan; self.groupKeys = groupKeys
        encodedDraft = try Self.encode(draft)
    }

    func messages(replySource: TelegramMessageActionSource?) -> [EnqueueMessage]? {
        let byID = Dictionary(uniqueKeysWithValues: resources.map { ($0.item.id, $0) })
        var result: [EnqueueMessage] = []
        for entry in plan.messages {
            let reference: AnyMediaReference?
            if let itemID = entry.itemID {
                guard let value = byID[itemID]?.reference else { return nil }
                reference = value
            } else { reference = nil }
            guard let message = telegramUploadMessage(caption: entry.caption, reference: reference, target: target,
                replySource: replySource, captionAboveMedia: entry.captionAboveMedia, mediaSpoiler: entry.mediaSpoiler,
                presentation: draft.schemaVersion >= 8 ? draft.presentation : nil,
                isOneTime: entry.itemID.flatMap { byID[$0]?.item.file.metadata?.voice?.isOneTime } ?? false) else { return nil }
            result.append(message.withUpdatedGroupingKey { _ in entry.groupIndex.map { groupKeys[$0] } })
        }
        return result
    }

    nonisolated func validate(transaction: Transaction) -> Bool {
        guard case let .success(current) = telegramPendingUploadRead(transaction: transaction,
            accountID: target.accountID, chatID: target.chatID), let current,
              (try? Self.encode(current)) == encodedDraft else { return false }
        if draft.items.first?.metadata?.voice?.isOneTime == true {
            let peerID = PeerId(target.chatID)
            guard telegramVoiceOnceEligibility(peer: transaction.getPeer(peerID),
                cachedData: transaction.getPeerCachedData(peerId: peerID), accountID: target.accountID,
                now: 0) == .allowed else { return false }
        }
        for entry in plan.messages {
            if entry.itemID == nil {
                guard telegramFormattedTextCanSend(entry.caption, transaction: transaction) else { return false }
            } else if !telegramFormattedCaptionCanSend(entry.caption, transaction: transaction) { return false }
        }
        if let source = target.replySource {
            let id = MessageId(peerId: PeerId(source.peerID), namespace: source.namespace, id: source.messageID)
            guard let message = transaction.getMessage(id) else { return false }
            let fresh = TelegramMessageActionSource(metadata: telegramMessageActionMetadata(message,
                limits: currentLimitsConfiguration(transaction: transaction)), accountID: target.accountID, chatID: target.chatID)
            guard fresh.canReply, fresh.fingerprint == source.fingerprint,
                  fresh.threadID == source.threadID else { return false }
            if source.peerID != source.chatID {
                guard let group = transaction.getPeer(id.peerId) as? TelegramGroup,
                      group.migrationReference?.peerId == PeerId(source.chatID) else { return false }
            }
        }
        return true
    }

    nonisolated func acknowledge(transaction: Transaction, messageIDs: [MessageId?]) -> Bool {
        guard validate(transaction: transaction), messageIDs.count == plan.messages.count else { return false }
        let ids = messageIDs.compactMap { $0 }
        guard ids.count == messageIDs.count, Set(ids).count == ids.count else { return false }
        let byID = Dictionary(uniqueKeysWithValues: resources.map { ($0.item.id, $0) })
        for (id, entry) in zip(ids, plan.messages) {
            guard id.peerId.toInt64() == target.chatID, id.namespace == Namespaces.Message.Local,
                  let queued = transaction.getMessage(id), !queued.flags.contains(.Incoming), queued.flags.contains(.Unsent),
                  queued.forwardInfo == nil, queued.text.utf8.elementsEqual(entry.caption.text.utf8),
                  queued.groupingKey == entry.groupIndex.map({ groupKeys[$0] }), queued.threadId == target.replySource?.threadID else { return false }
            let entities = queued.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }
            guard entities.count <= 1, (entities.first?.entities ?? []) == entry.caption.engineEntities(),
                  queued.attributes.filter({ $0 is InvertMediaMessageAttribute }).count == (entry.captionAboveMedia ? 1 : 0),
                  queued.attributes.filter({ $0 is MediaSpoilerMessageAttribute }).count == (entry.mediaSpoiler ? 1 : 0) else { return false }
            let replies = queued.attributes.compactMap { $0 as? ReplyMessageAttribute }
            if let source = target.replySource {
                guard replies.count == 1, Self.replyMatches(replies[0], source: source, target: target, transaction: transaction) else { return false }
            } else if !replies.isEmpty { return false }
            if let itemID = entry.itemID {
                guard queued.media.count == 1, let resource = byID[itemID], let expected = resource.reference?.media,
                      expected.isEqual(to: queued.media[0]) else { return false }
                if let voice = resource.item.file.metadata?.voice {
                    // Ordinary chat auto-delete is a separate Autoremove
                    // attribute. Native enqueue normalizes explicit media TTL
                    // to Autoclear and must not lose or add one-time intent.
                    let values = queued.attributes.compactMap { $0 as? AutoclearTimeoutMessageAttribute }
                    if voice.isOneTime {
                        guard values.count == 1, values[0].timeout == viewOnceTimeout,
                            values[0].countdownBeginTime == nil else { return false }
                    } else if !values.isEmpty { return false }
                }
                // Upstream isEqual omits these fields; new uploads have neither.
                if let file = queued.media[0] as? TelegramMediaFile {
                    guard file.videoThumbnails.isEmpty,
                          telegramUploadNativeVideoCoverMatches(file.videoCover, resource: resource.videoCover) else { return false }
                    if let thumbnail = resource.videoThumbnail ?? resource.webPPreview ?? resource.gifPreview {
                        guard file.previewRepresentations.count == 1, thumbnail.matches(file.previewRepresentations[0]) else { return false }
                    } else if !file.previewRepresentations.isEmpty { return false }
                }
                if let image = queued.media[0] as? TelegramMediaImage {
                    guard image.reference == nil, image.representations.allSatisfy({
                        $0.progressiveSizes.isEmpty && $0.immediateThumbnailData == nil &&
                            !$0.hasVideo && !$0.isPersonal && $0.typeHint == .generic
                    }) else { return false }
                }
            } else if !queued.media.isEmpty { return false }
        }
        let accepted = draft.updating(captionInput: draft.captionInput, captionAboveMedia: draft.captionAboveMedia,
            mediaSpoiler: draft.mediaSpoiler, disposition: .acceptedBatch(messageIDs: ids.map(TelegramUploadQueueID.init)))
        if case .success = telegramPendingUploadWrite(transaction: transaction, accountID: target.accountID,
            draft: accepted, expectedRevision: draft.revision) { return true }
        return false
    }

    private static func encode(_ value: TelegramPendingUploadDraft) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private nonisolated static func replyMatches(_ reply: ReplyMessageAttribute, source: TelegramMessageActionSource,
                                                target: TelegramUploadTarget, transaction: Transaction) -> Bool {
        let id = MessageId(peerId: PeerId(source.peerID), namespace: source.namespace, id: source.messageID)
        guard reply.messageId == id, let original = transaction.getMessage(id), !reply.isQuote, reply.todoItemId == nil else { return false }
        let thread = original.id.namespace == Namespaces.Message.Cloud ? original.threadId.map {
            MessageId(peerId: id.peerId, namespace: Namespaces.Message.Cloud, id: Int32(clamping: $0))
        } : nil
        guard reply.threadMessageId == thread else { return false }
        // Native enqueue derives a full quote for a migrated-peer reply, even
        // though our canonical request has no user-selected quote or todo item.
        guard source.peerID != target.chatID else { return reply.quote == nil }
        guard let quote = reply.quote, quote.offset == nil, quote.text.utf8.elementsEqual(original.text.utf8),
              quote.entities == messageTextEntitiesInRange(entities: original.textEntitiesAttribute?.entities ?? [],
                range: NSRange(location: 0, length: original.text.utf16.count), onlyQuoteable: true) else { return false }
        let media = original.media.last { $0 is TelegramMediaImage || $0 is TelegramMediaFile }
        switch (quote.media, media) {
        case (nil, nil): return true
        case let (.some(actual), .some(expected)):
            let a = PostboxEncoder(), b = PostboxEncoder()
            a.encodeRootObject(actual); b.encodeRootObject(expected)
            return a.makeData() == b.makeData()
        default: return false
        }
    }
}
