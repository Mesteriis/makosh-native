#if DEBUG
import Foundation
import Postbox

/// Fixed synthetic windows for exercising the real navigation and views offline.
/// Compiled out of release builds and never used by the account adapter.
struct TelegramSyntheticPages {
    private let size = 50

    func chats(folder: TelegramChatFolder, anchor: ChatListIndex?) ->
        (items: [TelegramChat], previous: ChatListIndex?, next: ChatListIndex?) {
        let total = folder == .inbox ? 125 : 65
        let start = max(0, min(Int(anchor?.messageIndex.id.id ?? 1) - 1, total - 1))
        let end = min(start + size, total)
        let base: Int64 = folder == .inbox ? 10_000 : 20_000
        let items = (start..<end).map { offset in
            TelegramChat(id: base + Int64(offset + 1), title: "Тестовый диалог \(offset + 1)",
                preview: folder == .inbox ? "Синтетическая история" : "Синтетический архив", unreadCount: offset == 0 ? 3 : 0)
        }
        func cursor(_ offset: Int) -> ChatListIndex {
            ChatListIndex(pinningIndex: nil, messageIndex: messageIndex(chatID: base, id: offset + 1))
        }
        return (items, end < total ? cursor(end) : nil, start > 0 ? cursor(max(0, start - size)) : nil)
    }

    func messages(chatID: Int64, anchor: MessageIndex?) ->
        (items: [TelegramMessage], previous: MessageIndex?, next: MessageIndex?) {
        let total = 130
        let end = min(total, max(1, Int(anchor?.id.id ?? Int32(total))))
        let start = max(0, end - size)
        let items = ((start + 1)...end).map { id in
            var message = TelegramMessage(id: "synthetic:\(chatID):\(id)", date: Date(timeIntervalSince1970: 1_700_000_000 + Double(id * 60)),
                text: "Тестовое сообщение \(id) • диалог \(chatID)", author: id.isMultiple(of: 2) ? "Макош QA" : "Тестовый собеседник",
                isOutgoing: id.isMultiple(of: 2), delivery: "")
            if [25, 124, 125, 126, 127, 128, 129, 130].contains(id) {
                let kind: TelegramAttachmentKind = id == 130 ? .photo : id == 128 ? .unsupported : .file
                let playback: TelegramPlaybackKind? = id == 124 ? .roundVideo : id == 125 ? .voice : id == 126 ? .audio : id == 127 ? .video : nil
                let playbackName = id == 124 ? "Синтетическое круглое видео QA.mp4" : id == 125 ? "Синтетическое голосовое QA.ogg" : id == 126 ? "Синтетическое аудио QA.wav" : "Синтетическое видео QA.mp4"
                message.attachments = [TelegramAttachment(id: "synthetic-attachment:\(chatID):\(id)", kind: kind,
                    name: playback != nil ? playbackName : kind == .photo ? "Синтетическое фото QA.png" : kind == .file ? "Синтетический файл QA.txt" : "Вложение не поддерживается",
                    byteCount: nil, mimeType: kind == .file ? "text/plain" : nil,
                    hasPreview: kind == .photo, canDownload: kind != .unsupported, playback: playback)]
            }
            let caption = !message.attachments.isEmpty
            let unsupported = message.attachments.contains { $0.kind == .unsupported }
            let entities: [TelegramTextEntity]
            if id == 121 {
                let secret = "СЕКРЕТ_QA_121", link = "Открыть документацию"
                message = TelegramMessage(id: message.id, date: message.date,
                    text: message.text + "\nСкрытый фрагмент: " + secret + "\n" + link,
                    author: message.author, isOutgoing: message.isOutgoing, delivery: message.delivery)
                let text = message.text as NSString, hidden = text.range(of: secret), linked = text.range(of: link)
                entities = [.init(offset: 0, length: 8, kind: .bold),
                    .init(offset: hidden.location, length: hidden.length, kind: .spoiler),
                    .init(offset: linked.location, length: linked.length, kind: .textURL(url: "https://example.invalid/docs"))]
            } else if [117, 118, 120].contains(id) {
                let code = id == 117 ? "  let café = \"😀\"\n  let hidden = \"SECRET_CODE_QA\"\n" : "  let value = \"CODE_QA_\(id) 😀\"\n"
                message = TelegramMessage(id: message.id, date: message.date, text: message.text + "\nБлок кода QA \(id)\n" + code,
                    author: message.author, isOutgoing: message.isOutgoing, delivery: message.delivery)
                let text = message.text as NSString, range = text.range(of: code)
                var captured = [TelegramTextEntity(offset: range.location, length: range.length, kind: .pre(language: "swift"))]
                if id == 117 {
                    let hidden = text.range(of: "SECRET_CODE_QA")
                    captured.append(.init(offset: hidden.location, length: hidden.length, kind: .spoiler))
                }
                entities = captured
            } else if [119, 123].contains(id) {
                let quote = id == 123 ? "ЦИТАТА_QA_123 первая строка\nВторая строка\nТретья строка\nЧетвёртая строка" : "ЦИТАТА_QA_119 первая строка\nВторая строка\nТретья строка"
                message = TelegramMessage(id: message.id, date: message.date, text: message.text + "\n" + quote,
                    author: message.author, isOutgoing: message.isOutgoing, delivery: message.delivery)
                let range = (message.text as NSString).range(of: quote)
                entities = [.init(offset: range.location, length: range.length, kind: .blockQuote(isCollapsed: true))]
            } else { entities = id == 122 ? [.init(offset: 0, length: 8, kind: .bold)] : [] }
            message.actionMetadata = TelegramMessageActionMetadata(peerID: chatID, namespace: 0, messageID: Int32(id),
                fingerprint: "synthetic-version-1-\(chatID)-\(id)", text: message.text,
                authorID: message.isOutgoing ? -1 : 999, canReply: true, canEdit: message.isOutgoing && !unsupported,
                canForward: id != 120, canDeleteLocally: true, canDeleteForEveryone: message.isOutgoing,
                allowsEmptyEdit: caption && !unsupported, editLimit: caption ? 1024 : 4096,
                formattedText: try? TelegramFormattedText(text: message.text, entities: entities), canCopy: id != 120)
            return message
        }
        return (items, start > 0 ? messageIndex(chatID: chatID, id: start) : nil,
            end < total ? messageIndex(chatID: chatID, id: min(total, end + size)) : nil)
    }

    private func messageIndex(chatID: Int64, id: Int) -> MessageIndex {
        MessageIndex(id: MessageId(peerId: PeerId(chatID), namespace: 0, id: Int32(id)), timestamp: Int32(id))
    }

    func searchChats(folder: TelegramChatFolder, query: String) -> [TelegramChat] {
        var result: [TelegramChat] = []
        var anchor: ChatListIndex?
        repeat {
            let page = chats(folder: folder, anchor: anchor)
            result.append(contentsOf: page.items)
            anchor = page.previous
        } while anchor != nil
        return result.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    func searchMessages(chatID: Int64, query: String) -> (items: [TelegramMessage], indexes: [String: MessageIndex]) {
        var result: [TelegramMessage] = []
        var anchor: MessageIndex?
        repeat {
            let page = messages(chatID: chatID, anchor: anchor)
            result.append(contentsOf: page.items.reversed())
            anchor = page.previous
        } while anchor != nil
        result = result.filter { $0.text.localizedCaseInsensitiveContains(query) }
        let indexes = Dictionary(uniqueKeysWithValues: result.compactMap { item -> (String, MessageIndex)? in
            guard let id = item.id.split(separator: ":").last.flatMap({ Int($0) }) else { return nil }
            return (item.id, messageIndex(chatID: chatID, id: id))
        })
        return (result, indexes)
    }
}
#endif
