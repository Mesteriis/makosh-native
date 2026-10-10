import Foundation

public enum TelegramChatFolder: String, CaseIterable, Identifiable, Sendable {
    case inbox, archive
    public var id: Self { self }
    public var title: String { self == .inbox ? "Диалоги" : "Архив" }
}

public struct TelegramPageNavigation: Equatable, Sendable {
    public let isLoading: Bool
    public let canLoadPrevious: Bool
    public let canLoadNext: Bool
    public let isAtLatest: Bool
    public let hasPreviousGap: Bool
    public let hasNextGap: Bool
    public let timedOut: Bool

    static let idle = TelegramPageNavigation(isLoading: false, canLoadPrevious: false,
        canLoadNext: false, isAtLatest: true, hasPreviousGap: false, hasNextGap: false, timedOut: false)
}

extension TelegramPageTracker {
    var navigation: TelegramPageNavigation {
        TelegramPageNavigation(isLoading: status == .loading, canLoadPrevious: canLoadPrevious,
            canLoadNext: canLoadNext, isAtLatest: isAtLatest, hasPreviousGap: hasPreviousGap,
            hasNextGap: hasNextGap, timedOut: status == .timedOut)
    }
}
