import Foundation

public struct TelegramForumTopic: Identifiable, Equatable, Sendable {
    public let accountID: Int64
    public let chatID: Int64
    public let threadID: Int64
    public let title: String
    public let iconFileID: Int64?
    public let iconColor: Int32
    public let unreadCount: Int32
    public let isMarkedUnread: Bool
    public let isClosed: Bool
    public let isHidden: Bool
    public let isOwnedByMe: Bool
    public let pinnedIndex: Int?
    public let lastMessage: TelegramMessage?
    public let draft: TelegramFormattedText?
    public let isMuted: Bool
    public var id: String { "\(accountID):\(chatID):\(threadID)" }

    public init(accountID: Int64, chatID: Int64, threadID: Int64, title: String,
        iconFileID: Int64? = nil, iconColor: Int32 = 0, unreadCount: Int32 = 0,
        isMarkedUnread: Bool = false, isClosed: Bool = false, isHidden: Bool = false,
        isOwnedByMe: Bool = false, pinnedIndex: Int? = nil, lastMessage: TelegramMessage? = nil,
        draft: TelegramFormattedText? = nil, isMuted: Bool = false) {
        self.accountID = accountID; self.chatID = chatID; self.threadID = threadID; self.title = title
        self.iconFileID = iconFileID; self.iconColor = iconColor; self.unreadCount = unreadCount
        self.isMarkedUnread = isMarkedUnread; self.isClosed = isClosed; self.isHidden = isHidden
        self.isOwnedByMe = isOwnedByMe; self.pinnedIndex = pinnedIndex; self.lastMessage = lastMessage
        self.draft = draft; self.isMuted = isMuted
    }
}

public struct TelegramForumTopicsSnapshot: Equatable, Sendable {
    public let accountID: Int64
    public let chatID: Int64
    public let topics: [TelegramForumTopic]
    public let isLoading: Bool
    public init(accountID: Int64, chatID: Int64, topics: [TelegramForumTopic], isLoading: Bool) {
        self.accountID = accountID; self.chatID = chatID; self.topics = topics; self.isLoading = isLoading
    }
}

public enum TelegramForumTopicsError: Error, Equatable, Sendable {
    case unavailable
    case incompatible
}

public enum TelegramForumTopicsPhase: Equatable, Sendable {
    case idle
    case loading
    case ready
    case failed(TelegramForumTopicsError)
}
