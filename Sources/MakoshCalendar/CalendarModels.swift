import Foundation

/// Where a calendar account's events come from.
public enum CalendarAccountKind: String, Codable, Sendable {
    case local, google, caldav, subscription
}

/// Working hours of an account: shading only, never busy time.
/// Keys are weekdays 1…7 (1 = Monday), ranges are minutes from midnight.
public struct CalendarWorkingHours: Codable, Equatable, Sendable {
    public var days: [Int: [ClosedRange<Int>]]
    public init(days: [Int: [ClosedRange<Int>]] = [:]) { self.days = days }

    public func contains(weekday: Int, minute: Int) -> Bool {
        days[weekday]?.contains { $0.contains(minute) } ?? false
    }
}

public enum CalendarAccountState: String, Codable, Sendable {
    case connected, needsSignIn, adminBlocked, unreachable, disabled
}

/// Failures carry codes and stages only: never response bodies, URLs or tokens.
public enum CalendarFailure: Error, Codable, Equatable, Sendable {
    case invalidSchema
    case notOpen
    case notFound
    case staleRevision
    case keyUnavailable
    case storage(String?)
    case invalidInput(String)
    case rejected(code: Int, stage: String)
    case unknownOutcome(stage: String)
    case signInRequired
    case adminBlocked
    case unreachable
}

public struct CalendarAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: CalendarAccountKind
    public var name: String
    public var workingHours: CalendarWorkingHours
    /// The Google grant's subject; the grant itself lives in the Keychain.
    public var googleGrantID: String?
    public var caldavServer: URL?
    public var caldavLogin: String?
    public var subscriptionURL: URL?
    /// Whether the CalDAV server sends invitations itself (RFC 6638 auto-schedule).
    public var serverSchedules: Bool?
    public var state: CalendarAccountState
    public var lastError: CalendarFailure?

    public init(
        id: UUID = UUID(), kind: CalendarAccountKind, name: String, workingHours: CalendarWorkingHours = .init(),
        googleGrantID: String? = nil, caldavServer: URL? = nil, caldavLogin: String? = nil, subscriptionURL: URL? = nil,
        serverSchedules: Bool? = nil, state: CalendarAccountState = .connected, lastError: CalendarFailure? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.workingHours = workingHours
        self.googleGrantID = googleGrantID
        self.caldavServer = caldavServer
        self.caldavLogin = caldavLogin
        self.subscriptionURL = subscriptionURL
        self.serverSchedules = serverSchedules
        self.state = state
        self.lastError = lastError
    }
}

public enum CalendarAccess: String, Codable, Sendable {
    case read, write
}

/// One calendar (a Google calendar, a CalDAV collection, a subscription, the local one).
public struct CalendarCollection: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var accountID: UUID
    public var externalID: String
    public var name: String
    public var color: String
    public var access: CalendarAccess
    public var shown: Bool
    public var defaultReminderMinutes: Int
    public var groupIDs: Set<UUID>

    public init(
        id: UUID = UUID(), accountID: UUID, externalID: String, name: String, color: String = "#8b5cf6", access: CalendarAccess = .write,
        shown: Bool = true, defaultReminderMinutes: Int = 10, groupIDs: Set<UUID> = []
    ) {
        self.id = id
        self.accountID = accountID
        self.externalID = externalID
        self.name = name
        self.color = color
        self.access = access
        self.shown = shown
        self.defaultReminderMinutes = defaultReminderMinutes
        self.groupIDs = groupIDs
    }
}

/// A busy group: calendars sharing at least one group see each other's busy time.
public struct CalendarGroup: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public enum CalendarTransparency: String, Codable, Sendable { case busy, free }
public enum CalendarEventStatus: String, Codable, Sendable { case confirmed, tentative, cancelled }
public enum CalendarResponse: String, Codable, Sendable { case needsAction, accepted, tentative, declined }

public struct CalendarAttendee: Codable, Equatable, Sendable {
    public var email: String
    public var name: String?
    public var response: CalendarResponse
    public var isSelf: Bool
    public var isOrganizer: Bool
    public init(
        email: String, name: String? = nil, response: CalendarResponse = .needsAction, isSelf: Bool = false, isOrganizer: Bool = false
    ) {
        self.email = email
        self.name = name
        self.response = response
        self.isSelf = isSelf
        self.isOrganizer = isOrganizer
    }
}

public struct CalendarRecurrence: Codable, Equatable, Sendable {
    /// The RRULE value without the `RRULE:` prefix.
    public var rrule: String
    public var exdates: [Date]
    public init(rrule: String, exdates: [Date] = []) {
        self.rrule = rrule
        self.exdates = exdates
    }
}

/// A date without time, for all-day events: copied as days, never as instants.
public struct CalendarDay: Codable, Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

public enum CalendarEventTime: Codable, Equatable, Sendable {
    case timed(start: Date, end: Date, timeZone: String?)
    case allDay(start: CalendarDay, endExclusive: CalendarDay)
}

/// The mark Makosh puts on a busy copy: which original and which occurrence it stands for.
public struct CalendarBusyMarker: Codable, Equatable, Hashable, Sendable {
    public var sourceEventID: UUID
    public var occurrenceStart: Date
    public init(sourceEventID: UUID, occurrenceStart: Date) {
        self.sourceEventID = sourceEventID
        self.occurrenceStart = occurrenceStart
    }
}

public struct CalendarEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var collectionID: UUID
    public var externalID: String?
    public var uid: String
    public var title: String
    public var notes: String
    public var location: String
    public var time: CalendarEventTime
    public var recurrence: CalendarRecurrence?
    /// Set on an override of one occurrence of a series: that occurrence's original start.
    public var recurrenceID: Date?
    public var masterID: UUID?
    public var attendees: [CalendarAttendee]
    public var organizerEmail: String?
    public var reminders: [Int]
    public var meetingURL: URL?
    public var transparency: CalendarTransparency
    public var status: CalendarEventStatus
    public var taskID: UUID?
    public var busyMarker: CalendarBusyMarker?
    public var etag: String?
    public var revision: Int64
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), collectionID: UUID, externalID: String? = nil, uid: String, title: String, notes: String = "",
        location: String = "", time: CalendarEventTime, recurrence: CalendarRecurrence? = nil, recurrenceID: Date? = nil,
        masterID: UUID? = nil, attendees: [CalendarAttendee] = [], organizerEmail: String? = nil, reminders: [Int] = [],
        meetingURL: URL? = nil, transparency: CalendarTransparency = .busy, status: CalendarEventStatus = .confirmed,
        taskID: UUID? = nil, busyMarker: CalendarBusyMarker? = nil, etag: String? = nil, revision: Int64 = 0,
        updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id
        self.collectionID = collectionID
        self.externalID = externalID
        self.uid = uid
        self.title = title
        self.notes = notes
        self.location = location
        self.time = time
        self.recurrence = recurrence
        self.recurrenceID = recurrenceID
        self.masterID = masterID
        self.attendees = attendees
        self.organizerEmail = organizerEmail
        self.reminders = reminders
        self.meetingURL = meetingURL
        self.transparency = transparency
        self.status = status
        self.taskID = taskID
        self.busyMarker = busyMarker
        self.etag = etag
        self.revision = revision
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isBusyCopy: Bool { busyMarker != nil }
    public var selfResponse: CalendarResponse? { attendees.first(where: \.isSelf)?.response }
    /// Whether this event occupies time for the busy groups: an original, not free,
    /// not cancelled, not declined by the user and not deleted.
    public var givesBusy: Bool {
        busyMarker == nil && transparency == .busy && status != .cancelled && selfResponse != .declined && deletedAt == nil
    }
}
