import Foundation

/// Which messages of a chat an AI context card includes. It lives in the core
/// so a service can read its own history for a card without importing the AI module.
public enum AIContextRange: Codable, Hashable, Sendable {
    /// The newest messages, at most this many.
    case latest(Int)
    /// Messages from the last days.
    case lastDays(Int)
    /// Messages dated within both bounds, inclusive.
    case between(Date, Date)

    public static let standard = AIContextRange.latest(200)
}
