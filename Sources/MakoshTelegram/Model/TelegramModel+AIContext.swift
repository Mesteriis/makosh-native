import Foundation

extension TelegramModel {
    /// Reads local history for AI context cards; nil until the account is ready.
    public var aiContextReader: (any TelegramAIContextReading)? {
        guard phase == .ready, let account else { return nil }
        return TelegramEngineAIContextReader(account: account)
    }
}
