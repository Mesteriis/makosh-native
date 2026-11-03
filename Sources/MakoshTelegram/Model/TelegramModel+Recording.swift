import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Voice and round-video recording preparation and sending.
extension TelegramModel {
    public var canStartVoiceRecording: Bool {
        !calls.isBusy && !voiceRecording.isActive && upload.phase == .idle && composerInput == .empty && messageEditSession == nil
            && !isRestoringComposerDraft && !isComposerSuspended && !composerReply.preventsSend
            && uploadTarget(replyTo: composerReply.resolved?.source, contextID: conversationGeneration) != nil
            && uploadTarget.map { canPrepareUpload(target: $0, contextID: conversationGeneration) } == true
    }

    public func beginVoiceRecording() {
        guard canStartVoiceRecording,
            let target = uploadTarget(replyTo: composerReply.resolved?.source, contextID: conversationGeneration)
        else { return }
        playback.stop()
        voiceRecording.begin(target: target, contextID: conversationGeneration)
    }

    public func beginVoiceRecording(contextID: UUID) {
        guard contextID == voiceInputContextID else { return }
        beginVoiceRecording()
    }

    public func cancelVoiceRecording() {
        voiceRecording.cancel()
        cancelVoicePreparation()
    }

    func cancelVoicePreparation() {
        voiceInputContextID = UUID()
        voiceEligibilityRequest.cancel()
        if let id = voicePreparationID, upload.canCancel { upload.dismissPreparation(contextID: id) }
        voicePreparationID = nil
    }

    func canPrepareUpload(target: TelegramUploadTarget, contextID: UUID) -> Bool {
        guard messageSelection.session == nil, !isRestoringPendingUpload, pendingUploadRecoveryError == nil,
            contextID == conversationGeneration, phase == .ready, !messageActions.isBusy, messageActions.phase != .uncertain,
            !selectedMessagesDeletionBlocksActions,
            drafts.snapshot(accountID: target.accountID, chatID: target.chatID, threadID: target.selectedThreadID)?.forwardIntent == nil,
            selectedChatID != target.chatID || (composerDraftRecoveryError == nil && serverDraftConflict == nil && !isResolvingServerDraft),
            target.accountID == draftAccountID, knownChats[target.chatID] != nil, target.hasValidReplySource,
            target.chatID != selectedChatID || target.selectedThreadID == selectedThreadID
        else { return false }
        return true
    }

    func isCurrentVoice(_ target: TelegramUploadTarget, context: UUID) -> Bool {
        guard selectedChatID == target.chatID, target.accountID == draftAccountID,
            context == conversationGeneration, composerInput == .empty, messageEditSession == nil,
            !isRestoringComposerDraft, canPrepareUpload(target: target, contextID: context)
        else { return false }
        return drafts.snapshot(accountID: target.accountID, chatID: target.chatID, threadID: target.selectedThreadID)?.replyTarget
            == target.replySource.map(TelegramComposerReplyTarget.init(source:))
    }

    func authorizeRecording(kind: TelegramRecordingKind) async -> Bool {
        guard let target = uploadTarget(replyTo: composerReply.resolved?.source, contextID: conversationGeneration) else { return false }
        let context = conversationGeneration, inputContext = voiceInputContextID
        guard !calls.isBusy, isCurrentVoice(target, context: context), voiceRecording.isActive else { return false }
        #if DEBUG
        if isSyntheticPreview { return true }
        #endif
        return await recordingPermissions.authorize(
            kind: kind,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return !self.calls.isBusy && self.voiceInputContextID == inputContext && self.voiceRecording.isActive
                    && self.isCurrentVoice(target, context: context)
            })
    }

    func checkVoiceEligibility(
        _ target: TelegramUploadTarget, isOneTime: Bool = false,
        kind: TelegramRecordingKind = .voice
    ) async -> TelegramVoiceEligibility {
        guard target.accountID == draftAccountID, phase == .ready else { return .unavailable }
        #if DEBUG
        if isSyntheticPreview { return .allowed }
        #endif
        guard let account else { return .unavailable }
        return await voiceEligibilityRequest.check(account: account, target: target, isOneTime: isOneTime, kind: kind)
    }

    func prepareVoiceRecording(samples: [Int16], target: TelegramUploadTarget, context: UUID, send: Bool, isOneTime: Bool) async -> Bool {
        guard isCurrentVoice(target, context: context),
            upload.prepareRecordedVoice(samples: samples, target: target, isOneTime: isOneTime)
        else { return false }
        return await waitForRecordedPreparation(target: target, context: context, send: send)
    }

    func prepareRoundVideoRecording(bytes: Data, target: TelegramUploadTarget, context: UUID, send: Bool, isOneTime: Bool) async -> Bool {
        guard isCurrentVoice(target, context: context),
            upload.prepareRecordedRoundVideo(bytes: bytes, target: target, isOneTime: isOneTime)
        else { return false }
        return await waitForRecordedPreparation(target: target, context: context, send: send)
    }

    func waitForRecordedPreparation(target: TelegramUploadTarget, context: UUID, send: Bool) async -> Bool {
        guard let id = upload.preparationContextID else { return false }
        voicePreparationID = id
        // Wait only for this preparation's first durable receipt. A timeout,
        // failure, cancellation or changed context never creates a later send.
        let limit = ContinuousClock.now.advanced(by: .seconds(30))
        while !Task.isCancelled, voicePreparationID == id, upload.preparationContextID == id,
            isCurrentVoice(target, context: context), ContinuousClock.now < limit
        {
            if upload.canSend {
                // The recording owns a conversation token; the final send also
                // checks the independently scoped account token after eligibility.
                if send { await sendPreparedRecording(contextID: id, accountContext: accountGeneration, recordingIntent: id) }
                if voicePreparationID == id { voicePreparationID = nil }
                return true
            }
            if upload.phase != .preparing && (upload.phase != .ready || !upload.isRecoveryBusy) { break }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        // The visible durable preparation remains for an explicit action when
        // storage fails or takes too long. Never poll it into an automatic send.
        if voicePreparationID == id { voicePreparationID = nil }
        return upload.preparationContextID == id
    }

    public func sendPreparedVoice(contextID: UUID) {
        sendPreparedRecording(contextID: contextID)
    }

    public func sendPreparedRecording(contextID: UUID) {
        let context = accountGeneration
        Task { [weak self] in await self?.sendPreparedRecording(contextID: contextID, accountContext: context) }
    }

    func sendPreparedRecording(contextID: UUID, accountContext: UUID, recordingIntent: UUID? = nil) async {
        guard !Task.isCancelled, upload.preparationContextID == contextID, upload.isRecordedVoice || upload.isRecordedRoundVideo,
            upload.canSend,
            let target = upload.target, target.accountID == draftAccountID, accountContext == accountGeneration
        else { return }
        let kind: TelegramRecordingKind = upload.isRecordedRoundVideo ? .roundVideo : .voice
        let allowed: TelegramVoiceEligibility
        if kind == .roundVideo {
            if upload.isOneTimeRoundVideo {
                allowed = await voiceRecording.roundVideoOneTimeEligibility(target) ? .allowed : .restricted
            } else {
                allowed = await voiceRecording.roundVideoEligibility(target)
            }
        } else if upload.file?.metadata?.voice?.isOneTime == true {
            allowed = await voiceRecording.oneTimeEligibility(target) ? .allowed : .restricted
        } else {
            allowed = await voiceRecording.eligibility(target)
        }
        guard !Task.isCancelled, recordingIntent == nil || voicePreparationID == recordingIntent,
            accountContext == accountGeneration, upload.preparationContextID == contextID,
            upload.target == target, upload.canSend
        else { return }
        guard allowed == .allowed else {
            error = allowed.explanation(for: kind)
            return
        }
        upload.send(contextID: contextID)
    }
}
