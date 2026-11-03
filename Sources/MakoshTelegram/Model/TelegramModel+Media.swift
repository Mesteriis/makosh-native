import Foundation
import MakoshCore
import TelegramCore
import Postbox
import SwiftSignalKit

/// Media sources, automatic downloads and cache-removal eligibility.
extension TelegramModel {
    var permitsCloudCacheRemoval: Bool {
        phase == .ready && !isBusy && upload.phase == .idle && !voiceRecording.isActive && !archive.isArchiving && !archive.files.isBusy
            && archive.files.error == nil && media.inFlightCount == 0
    }

    @discardableResult public func setAutomaticDownloadsPaused(_ paused: Bool, contextID: UUID) -> Bool {
        guard autoDownloadSettings.accountID != nil, autoDownloadSettings.contextID == contextID else { return false }
        automaticDownloads.setPaused(paused)
        automaticDownloadsPaused = paused
        return true
    }

    public func setVisibleAutomaticDownloads(
        messageIDs: Set<String>, context: TelegramHistoryReadContext,
        windowIsActive: Bool, eligibility: @escaping @MainActor () -> Bool
    ) {
        guard historyReadContext == context else { return }
        let attachments = messages.filter { messageIDs.contains($0.id) && !$0.isOutgoing }.flatMap(\.attachments)
        automaticDownloads.replace(
            attachments: attachments, contextID: context.historyWindowID,
            active: windowIsActive,
            eligibility: { [weak self] in
                self?.historyReadContext == context && eligibility()
            })
    }

    public func cancelAutomaticDownloads() {
        automaticDownloads.replace(attachments: [], contextID: UUID(), active: false)
        media.cancelAutomaticDownloads(except: [])
    }

    public func cancelMediaLoads() {
        cancelAutomaticDownloads()
        playback.stop()
        media.retain(attachments: [])
        refreshMediaSources()
    }

    func refreshMediaSources() {
        let sources =
            historyMediaSources + Array(search.mediaSources.values) + Array(globalSearch.mediaSources.values)
            + Array(sharedMedia.mediaSources.values)
        var nativeSources = Dictionary(sources.map { ($0.attachment.id, $0) }, uniquingKeysWith: { _, last in last })
        if let provider = mediaProvider {
            for key in media.manualAttachmentKeys where nativeSources[key] == nil {
                if let source = provider.sources[key], source.attachment == media.retainedManualAttachment(key) {
                    nativeSources[key] = source
                }
            }
            provider.sources = nativeSources
        }
        let attachments = (messages + search.messages + globalSearch.messages + sharedMedia.messages).flatMap(\.attachments)
        playback.retain(attachments: attachments)
        media.retain(attachments: attachments)
        if let accountID = draftAccountID, !isSyntheticPreview {
            let archivedSources = Dictionary(
                sources.map { source in
                    let id = source.messageID, a = source.attachment
                    return (
                        a.id,
                        (
                            MessageArchiveIdentity(
                                service: "telegram", accountID: String(accountID),
                                conversationID: String(id.peerId.toInt64()), messageID: "\(id.namespace):\(id.id)"),
                            MessageArchiveAttachment(
                                id: a.id,
                                kind: a.kind == .photo
                                    ? "photo" : a.kind == .file ? "file" : a.kind == .location ? "location" : "unsupported", name: a.name,
                                size: a.byteCount)
                        )
                    )
                }, uniquingKeysWith: { _, last in last })
            media.completedFullFile = { [files = archive.files] id, url, size in
                guard let (identity, attachment) = archivedSources[id] else { return }
                files.accept(file: url, byteCount: size, identity: identity, attachment: attachment)
            }
            media.reserveAutomaticFile = { [files = archive.files] id in
                guard let (identity, attachment) = archivedSources[id] else { return nil }
                return files.reserveAutomaticCapture(identity: identity, attachment: attachment)
            }
            media.reserveManualFile = { [files = archive.files] id in
                guard let (identity, attachment) = archivedSources[id] else { return nil }
                return files.reserveManualDownload(identity: identity, attachment: attachment)
            }
        } else {
            media.completedFullFile = nil
            media.reserveAutomaticFile = nil
            media.reserveManualFile = nil
        }
    }
}
