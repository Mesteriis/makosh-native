import Foundation

/// What the section's interface shows about books and cards; persons come from the core.
public struct PersonsSnapshot: Equatable, Sendable {
    public var books: [PersonBook]
    public var entries: [PersonBookEntry]
    public var openAttempts: [PersonAttempt]
    /// Per person, per book: why a flagged person cannot reach that book.
    public var blocked: [UUID: [UUID: PersonsFailure]]
    public var preferences: PersonsPreferences
    public var googleAvailable: Bool
    public init(
        books: [PersonBook], entries: [PersonBookEntry], openAttempts: [PersonAttempt], blocked: [UUID: [UUID: PersonsFailure]],
        preferences: PersonsPreferences, googleAvailable: Bool
    ) {
        self.books = books
        self.entries = entries
        self.openAttempts = openAttempts
        self.blocked = blocked
        self.preferences = preferences
        self.googleAvailable = googleAvailable
    }
}
