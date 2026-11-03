import TelegramCore

enum TelegramUploadCaptionLimit {
    /// The configured tier belongs to the selected account. Callers retain the
    /// selected limit in new preparations; old preparations keep their1024 rule.
    static func resolve(appConfiguration: AppConfiguration, isPremium: Bool) -> Int {
        let fallback = isPremium ? 2048 : 1024
        let key = isPremium ? "caption_length_limit_premium" : "caption_length_limit_default"
        guard case let .dictionary(values)? = appConfiguration.data,
              case let .number(value)? = values[key], value.isFinite,
              value >= 1, value <= Double(Int32.max), value.rounded(.towardZero) == value else {
            return fallback
        }
        return Int(value)
    }

    static func isValid(_ value: Int) -> Bool { (1...Int(Int32.max)).contains(value) }
}
