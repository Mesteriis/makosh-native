import Foundation

/// A rough token count without the model's tokenizer: Cyrillic text costs
/// about 2.5 characters per token, everything else about 4.
public enum AITokenEstimate {
    public static let defaultContextTokens = 128_000
    /// The share of the model's context kept free for its answer.
    public static let answerReserve = 0.15
    static let cyrillicCharactersPerToken = 2.5
    static let otherCharactersPerToken = 4.0

    public static func tokens(in text: String) -> Int {
        var cyrillic = 0, other = 0
        for scalar in text.unicodeScalars {
            if (0x0400...0x04FF).contains(scalar.value) { cyrillic += 1 } else { other += 1 }
        }
        return Int((Double(cyrillic) / cyrillicCharactersPerToken).rounded(.up))
            + Int((Double(other) / otherCharactersPerToken).rounded(.up))
    }

    /// Tokens a conversation may spend on history and cards for this model.
    public static func budget(contextTokens: Int?) -> Int {
        let context = contextTokens.map { $0 > 0 ? $0 : defaultContextTokens } ?? defaultContextTokens
        return Int(Double(context) * (1 - answerReserve))
    }
}
