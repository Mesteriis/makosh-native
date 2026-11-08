import Foundation

public enum CalendarAttemptKind: String, Codable, Sendable {
    case createEvent, updateEvent, deleteEvent, respond, createCopy, moveCopy, deleteCopy
}

public enum CalendarAttemptState: String, Codable, Sendable {
    case queued, sent, confirmed, rejected, unknown

    public var isOpen: Bool { self == .queued || self == .sent || self == .unknown }
}

/// One write to an external calendar. An `unknown` outcome is never retried by
/// itself: a reread settles it, or the user dismisses it.
public struct CalendarAttempt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let eventID: UUID?
    public let copyID: UUID?
    public let collectionID: UUID
    public let kind: CalendarAttemptKind
    public var state: CalendarAttemptState
    /// What the check needs to find the write again; never secrets.
    public let payload: Data
    public var failure: CalendarFailure?
    public let createdAt: Date
    public var updatedAt: Date
    public var resolvedAt: Date?
}
