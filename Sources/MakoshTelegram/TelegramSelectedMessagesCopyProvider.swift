import Foundation
import Postbox
import TelegramCore
import SwiftSignalKit

enum TelegramSelectedCopyMedia: Sendable { case photo, file(String), voice, video, roundVideo, sticker, music, animation, other }

struct TelegramSelectedCopyItem: Sendable {
    let author: String
    let formatted: TelegramFormattedText?
    let attachments: [TelegramAttachment]
    let maskServiceCodes: Bool
    var media: TelegramSelectedCopyMedia? = nil
}

@MainActor func telegramSelectedCopyText(_ items: [TelegramSelectedCopyItem]) -> String {
    items.map { item in
        var text = item.formatted.map { TelegramMessagePresentation.plainText($0) } ?? "Форматирование сообщения недоступно"
        if item.maskServiceCodes, let expression = try? NSRegularExpression(pattern: #"[\d\-]{3,7}"#) {
            let mutable = NSMutableString(string: text)
            for match in expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).reversed() {
                mutable.replaceCharacters(in: match.range, with: String(repeating: "█", count: match.range.length))
            }
            text = mutable as String
        }
        let media = item.media ?? item.attachments.first.map { attachment -> TelegramSelectedCopyMedia in
            switch attachment.playback {
            case .voice: return .voice
            case .video: return .video
            case .roundVideo: return .roundVideo
            case .audio: return .music
            case nil: break
            }
            switch attachment.kind {
            case .photo: return .photo
            case .file: return .file(attachment.name)
            case .unsupported: return .other
            }
        }
        if let media {
            switch media {
            case .photo: text = text.isEmpty ? "Фото" : "🖼 " + text
            case let .file(name): text = text.isEmpty ? (name.isEmpty ? "Файл" : name) : "📎 " + text
            case .voice: text = text.isEmpty ? "Голосовое сообщение" : "🎤 " + text
            case .video: text = text.isEmpty ? "Видео" : "📹 " + text
            case .roundVideo: text = "Видеосообщение"
            case .sticker: text = "Стикер"
            case .music: text = "Музыка"
            case .animation: text = text.isEmpty ? "GIF" : "GIF, " + text
            case .other: if text.isEmpty { text = "Вложение" }
            }
        }
        return "> " + item.author + ":\n" + text
    }.joined(separator: "\n\n")
}

nonisolated func telegramSelectedCopyItems(postbox: Postbox, accountID: Int64,
                                           request: TelegramSelectedMessagesCopyRequest) -> Signal<[TelegramSelectedCopyItem]?, NoError> {
    postbox.transaction { transaction in
        guard request.accountID == accountID, !request.sources.isEmpty, request.sources.count <= 100 else { return nil }
        let ids = request.sources.map { MessageId(peerId: PeerId($0.peerID), namespace: $0.namespace, id: $0.messageID) }
        guard Set(ids).count == ids.count else { return nil }
        var items: [TelegramSelectedCopyItem] = []
        for frozen in request.sources.sorted(by: {
            MessageId(peerId: PeerId($0.peerID), namespace: $0.namespace, id: $0.messageID) < MessageId(peerId: PeerId($1.peerID), namespace: $1.namespace, id: $1.messageID)
        }) {
            let id = MessageId(peerId: PeerId(frozen.peerID), namespace: frozen.namespace, id: frozen.messageID)
            guard frozen.accountID == accountID, frozen.chatID == request.chatID, frozen.canCopy,
                  let message = transaction.getMessage(id) else { return nil }
            let fresh = TelegramMessageActionSource(metadata: telegramMessageActionMetadata(message), accountID: accountID, chatID: request.chatID)
            guard fresh.canCopy, fresh.threadID == frozen.threadID,
                  fresh.fingerprint.utf8.elementsEqual(frozen.fingerprint.utf8) else { return nil }
            if frozen.peerID != request.chatID {
                guard let group = transaction.getPeer(id.peerId) as? TelegramGroup,
                      group.migrationReference?.peerId == PeerId(request.chatID) else { return nil }
            }
            let forward = message.forwardInfo
            let author = forward?.author.map(telegramPeerTitle) ?? forward?.authorSignature ?? message.author.map(telegramPeerTitle) ?? "Telegram"
            let rawPeer = id.peerId.id._internalGetInt64Value()
            var attachments = telegramAttachments(message).map(\.attachment)
            if attachments.isEmpty && !message.media.isEmpty {
                attachments = [.init(id: "summary", kind: .unsupported, name: "", byteCount: nil,
                                     mimeType: nil, hasPreview: false, canDownload: false)]
            }
            var style: TelegramSelectedCopyMedia?
            if message.media.first is TelegramMediaImage { style = .photo }
            else if let file = message.media.first as? TelegramMediaFile {
                if file.isSticker || file.isAnimatedSticker { style = .sticker }
                else if file.isVoice { style = .voice }
                else if file.isInstantVideo { style = .roundVideo }
                else if file.isVideo { style = file.isAnimated ? .animation : .video }
                else if file.isMusic { style = .music }
                else { style = .file(file.fileName ?? "Файл") }
            }
            items.append(.init(author: author, formatted: fresh.metadata.formattedText,
                attachments: attachments,
                maskServiceCodes: message.flags.contains(.Incoming) && id.namespace == Namespaces.Message.Cloud &&
                    id.peerId.namespace == Namespaces.Peer.CloudUser && [Int64(777000), Int64(489000)].contains(rawPeer), media: style))
        }
        return items
    }
}

@MainActor final class TelegramPostboxSelectedMessagesCopyProvider: TelegramSelectedMessagesCopyProvider {
    let accountID: Int64
    private let postbox: Postbox
    init(postbox: Postbox, accountID: Int64) { self.postbox = postbox; self.accountID = accountID }
    func resolve(request: TelegramSelectedMessagesCopyRequest, completion: @escaping @MainActor (String?) -> Void) -> Disposable {
        (telegramSelectedCopyItems(postbox: postbox, accountID: accountID, request: request) |> deliverOnMainQueue)
            .start(next: { items in MainActor.assumeIsolated { completion(items.map(telegramSelectedCopyText)) } })
    }
}

#if DEBUG
@MainActor final class TelegramSyntheticSelectedMessagesCopyProvider: TelegramSelectedMessagesCopyProvider {
    let accountID: Int64 = -1
    func resolve(request: TelegramSelectedMessagesCopyRequest, completion: @escaping @MainActor (String?) -> Void) -> Disposable {
        guard request.accountID == accountID, !request.sources.isEmpty, request.sources.count <= 100 else { completion(nil); return EmptyDisposable }
        let pages = TelegramSyntheticPages()
        var anchor: MessageIndex?, cached: [TelegramMessage] = []
        repeat { let page = pages.messages(chatID: request.chatID, anchor: anchor); cached += page.items; anchor = page.previous } while anchor != nil
        var seen = Set<TelegramMessageSelectionID>(), items: [TelegramSelectedCopyItem] = []
        for frozen in request.sources.sorted(by: { $0.namespace == $1.namespace ? $0.messageID < $1.messageID : $0.namespace < $1.namespace }) {
            guard seen.insert(.init(source: frozen)).inserted, frozen.accountID == accountID, frozen.chatID == request.chatID,
                  frozen.peerID == request.chatID, frozen.canCopy,
                  let message = cached.first(where: { $0.actionMetadata?.messageID == frozen.messageID && $0.actionMetadata?.namespace == frozen.namespace }),
                  let metadata = message.actionMetadata, metadata.canCopy, metadata.threadID == frozen.threadID,
                  metadata.fingerprint.utf8.elementsEqual(frozen.fingerprint.utf8) else { completion(nil); return EmptyDisposable }
            items.append(.init(author: message.author, formatted: metadata.formattedText, attachments: message.attachments, maskServiceCodes: false))
        }
        completion(telegramSelectedCopyText(items)); return EmptyDisposable
    }
}
#endif
