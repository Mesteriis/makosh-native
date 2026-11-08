import Foundation

public struct RemoteCollection: Equatable, Sendable {
    public let externalID: String
    public let name: String
    public let color: String?
    public let access: CalendarAccess
    public init(externalID: String, name: String, color: String?, access: CalendarAccess) {
        self.externalID = externalID
        self.name = name
        self.color = color
        self.access = access
    }
}

/// What changed in one calendar since the cursor. Busy copies come apart from
/// events: they are never sources.
public struct RemoteChangeSet: Sendable {
    public var events: [CalendarEvent]
    public var removedExternalIDs: [String]
    public var busyCopies: [ObservedBusyCopy]
    public var cursor: Data?
    /// The whole calendar was read: an event missing from it is gone.
    public var full: Bool
    public init(
        events: [CalendarEvent] = [], removedExternalIDs: [String] = [], busyCopies: [ObservedBusyCopy] = [], cursor: Data?, full: Bool
    ) {
        self.events = events
        self.removedExternalIDs = removedExternalIDs
        self.busyCopies = busyCopies
        self.cursor = cursor
        self.full = full
    }
}

public struct RemoteEventRef: Equatable, Sendable {
    public let externalID: String
    public let etag: String?
    public init(externalID: String, etag: String?) {
        self.externalID = externalID
        self.etag = etag
    }
}

/// One protocol for Google, CalDAV, subscriptions and the synthetic calendar.
public protocol CalendarAdapter: Sendable {
    func collections() async throws -> [RemoteCollection]
    func changes(collection: CalendarCollection, cursor: Data?, window: DateInterval) async throws -> RemoteChangeSet
    func create(_ event: CalendarEvent, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef
    func update(_ event: CalendarEvent, ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef
    func delete(ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws
    func respond(_ response: CalendarResponse, ref: RemoteEventRef, in collection: CalendarCollection) async throws -> RemoteEventRef
    func find(uid: String, in collection: CalendarCollection) async throws -> CalendarEvent?
    func createBusyCopy(_ copy: DesiredBusyCopy, in collection: CalendarCollection) async throws -> RemoteEventRef
    func moveBusyCopy(
        ref: RemoteEventRef, to time: CalendarEventTime, marker: CalendarBusyMarker, in collection: CalendarCollection
    )
        async throws -> RemoteEventRef
    var schedulesInvitations: Bool { get async }
}
