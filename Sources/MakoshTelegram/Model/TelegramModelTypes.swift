import Foundation

public enum TelegramPhase: Equatable {
    case configuration, connecting, phone, code, password(hint: String), ready, unsupported(String)
}

public struct TelegramChat: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let title: String
    public let preview: String
    public let unreadCount: Int
    public var presence: TelegramChatPresence? = nil
}

public struct TelegramMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let text: String
    public let author: String
    public let isOutgoing: Bool
    public let delivery: TelegramMessageDelivery
    public var attachments: [TelegramAttachment] = []
    public var actionMetadata: TelegramMessageActionMetadata? = nil
    public var albumGroupID: UInt32? = nil
    public var nativeGroupingKey: Int64? = nil
    public var canGroupMedia = true
    /// Received placement for supported photo/video; an album caption may belong to another member.
    public var captionAboveMedia = false
    /// Copy-protected or secret content: never forwarded, sent to Paperless or read by the AI.
    public var isProtected = false
    public mutating func markProtected() {
        isProtected = true
        attachments = attachments.map { attachment in
            var value = attachment
            value.isProtected = true
            return value
        }
    }
    public var formattedTextForDisplay: TelegramFormattedText? {
        guard let metadata = actionMetadata else { return try? TelegramFormattedText(text: text) }
        guard let value = metadata.formattedText, value.text.utf8.elementsEqual(text.utf8) else { return nil }
        return value
    }
}

public struct TelegramAPIConfiguration: Equatable, Sendable {
    public let id: Int32
    public let hash: String
    public init(id: String, hash: String) throws {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHash = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, trimmedID.utf8.allSatisfy({ (48...57).contains($0) }),
            let parsed = Int32(trimmedID), parsed > 0,
            trimmedHash.utf8.count == 32,
            trimmedHash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else {
            throw TelegramSetupError.invalidAPI
        }
        self.id = parsed
        self.hash = trimmedHash
    }
}

enum TelegramSetupError: LocalizedError {
    case invalidAPI, keychain, missingSessionKey, filesystem
    var errorDescription: String? {
        switch self {
        case .invalidAPI: "Укажите положительный API ID и API hash из 32 шестнадцатеричных символов, полученные для вашего приложения."
        case .keychain: "Не удалось открыть ключ сеанса в Связке ключей. Данные сеанса не изменены."
        case .missingSessionKey:
            "Ключ существующего сеанса недоступен. Восстановите Связку ключей; Макош не создаёт новый ключ поверх старых данных."
        case .filesystem: "Не удалось открыть отдельный каталог сеанса Макоша. Проверьте доступ к Application Support."
        }
    }
}

/// Own integration over the exact TelegramSwift engine gitlink. Initialization
/// performs no account, Keychain, filesystem or network access until Connect.
