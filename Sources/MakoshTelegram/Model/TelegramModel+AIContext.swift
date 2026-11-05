import Foundation

extension TelegramModel {
    /// Reads local history for AI context cards; nil until the account is ready.
    public var aiContextReader: (any TelegramAIContextReading)? {
        guard phase == .ready, let account else { return nil }
        return TelegramEngineAIContextReader(account: account)
    }
}

extension TelegramModel {
    /// The signed-in account, for AI context cards.
    public var aiContextAccountID: Int64? { phase == .ready ? draftAccountID : nil }
    /// Chats this window has loaded, newest list first, for "+" and "@".
    public var aiContextChats: [TelegramChat] {
        var seen = Set<Int64>()
        return (search.chats + Array(knownChats.values)).filter { seen.insert($0.id).inserted }
    }
}
