import Foundation

/// Caption input, placement, spoilers and custom emoji insertion.
extension TelegramUploadController {
    public internal(set) var file: TelegramUploadFile? {
        get {
            if presentation == .archive { return recoveredArchive?.file }
            return (items.first(where: { $0.id == selectedItemID }) ?? items.first)?.presented(as: presentation)?.file
        }
        set {
            guard let newValue else {
                items = []
                selectedItemID = nil
                return
            }
            if let index = items.firstIndex(where: { $0.id == selectedItemID }) {
                items[index] = .init(
                    id: items[index].id, file: newValue, originalFile: items[index].originalFile,
                    sourceFacts: items[index].sourceFacts)
            } else {
                items = [.init(id: newValue.id, file: newValue)]
                selectedItemID = newValue.id
            }
        }
    }

    struct CaptionEmojiInsertion {
        let request: TelegramCustomEmojiInsertionRequest
        let catalog: TelegramCustomEmojiCatalogController
        let catalogContextID: UUID
        let preparationID: UUID
        let captionRevision: UUID
        let itemsRevision: UUID
        let target: TelegramUploadTarget
        let bindingID: UUID
    }

    public var canInsertCaptionCustomEmoji: Bool {
        phase == .ready && recoveryPrepared && !isRecoveryBusy && appendOperationID == nil && videoCoverEditingID == nil
            && !isVideoCoverSaving && !containsRecordedMedia && captionPolicy != nil
            && (captionRules == .current || captionRules == .extended) && captionInput.formattedText.isEditable
    }

    @discardableResult
    public func requestCaptionCustomEmojiInsertion(
        descriptor: TelegramCustomEmojiDescriptor,
        catalog: TelegramCustomEmojiCatalogController, catalogContextID: UUID, expectedInput: TelegramComposerInput,
        contextID: UUID, revision: UUID, preparationID: UUID
    ) -> Bool {
        guard canInsertCaptionCustomEmoji, let target, self.preparationID == preparationID,
            token == contextID, captionRevision == revision, captionInput == expectedInput,
            catalog.contextID == catalogContextID, catalog.snapshot?.accountID == target.accountID,
            catalog.canInsert(descriptor, chatID: target.chatID),
            (try? TelegramCustomEmojiInsertion.applying(descriptor, to: expectedInput)) != nil
        else { return false }
        let request = TelegramCustomEmojiInsertionRequest(
            descriptor: descriptor,
            expectedInput: expectedInput, contextID: contextID)
        pendingCaptionEmojiInsertion = .init(
            request: request, catalog: catalog, catalogContextID: catalogContextID,
            preparationID: preparationID, captionRevision: revision, itemsRevision: itemsRevision,
            target: target, bindingID: bindingID)
        captionCustomEmojiInsertion = request
        return true
    }

    @discardableResult
    public func consumeCaptionCustomEmojiInsertion(id: UUID, expectedInput: TelegramComposerInput) -> Bool {
        guard let pending = pendingCaptionEmojiInsertion, pending.request.id == id,
            captionCustomEmojiInsertion == pending.request
        else { return false }
        pendingCaptionEmojiInsertion = nil
        captionCustomEmojiInsertion = nil
        return canInsertCaptionCustomEmoji && bindingID == pending.bindingID && preparationID == pending.preparationID
            && target == pending.target && captionRevision == pending.captionRevision && itemsRevision == pending.itemsRevision
            && token == pending.request.contextID && expectedInput == captionInput && expectedInput == pending.request.expectedInput
            && pending.catalog.contextID == pending.catalogContextID && pending.catalog.snapshot?.accountID == pending.target.accountID
            && pending.catalog.canInsert(pending.request.descriptor, chatID: pending.target.chatID)
    }

    @discardableResult
    public func updateMediaSpoiler(_ spoiler: Bool, contextID: UUID, revision: UUID) -> Bool {
        guard appendOperationID == nil, token == contextID, captionRevision == revision, phase == .ready, videoCoverEditingID == nil,
            !isVideoCoverSaving,
            canUseMediaOptions
        else { return false }
        if mediaSpoiler != spoiler {
            if spoiler { videoPlayback.stop() }
            mediaSpoiler = spoiler
            captionRevision = UUID()
            persistCaption()
        }
        return true
    }

    @discardableResult
    public func updateCaptionPlacement(_ above: Bool, contextID: UUID, revision: UUID) -> Bool {
        guard appendOperationID == nil, token == contextID, captionRevision == revision, phase == .ready, videoCoverEditingID == nil,
            !isVideoCoverSaving,
            canUseMediaOptions
        else { return false }
        if captionAboveMedia != above {
            captionAboveMedia = above
            captionRevision = UUID()
            persistCaption()
        }
        return true
    }

    public var caption: String {
        get { captionInput.formattedText.text }
        set {
            guard appendOperationID == nil, videoCoverEditingID == nil, !isVideoCoverSaving else { return }
            guard !containsRecordedMedia || newValue.isEmpty else { return }
            guard !newValue.utf8.elementsEqual(caption.utf8) else { return }
            guard let input = try? TelegramComposerInput(formattedText: TelegramFormattedText(text: newValue)) else {
                error = "Не удалось сохранить подпись."
                return
            }
            captionInput = input
            captionRevision = UUID()
            persistCaption()
        }
    }

    @discardableResult
    public func updateCaptionInput(_ input: TelegramComposerInput, contextID: UUID) -> Bool {
        guard appendOperationID == nil, token == contextID, phase == .ready, videoCoverEditingID == nil, !isVideoCoverSaving else {
            return false
        }
        guard !containsRecordedMedia || input == .empty else { return false }
        if captionInput != input {
            captionInput = input
            captionRevision = UUID()
            if captionRules == .current, captionPolicy != nil, TelegramUploadCaptionRules.containsCustomEmoji(input.formattedText) {
                captionRules = .extended
            }
        }
        error = nil
        persistCaption()
        return true
    }
}
