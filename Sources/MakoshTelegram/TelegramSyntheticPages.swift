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
            if [25, 128, 129, 130].contains(id) {
                let kind: TelegramAttachmentKind = id == 130 ? .photo : id == 128 ? .unsupported : .file
                message.attachments = [TelegramAttachment(id: "synthetic-attachment:\(chatID):\(id)", kind: kind,
                    name: kind == .photo ? "Синтетическое фото QA.png" : kind == .file ? "Синтетический файл QA.txt" : "Вложение не поддерживается",
                    byteCount: nil, mimeType: kind == .file ? "text/plain" : nil,
                    hasPreview: kind == .photo, canDownload: kind != .unsupported)]
            }
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
