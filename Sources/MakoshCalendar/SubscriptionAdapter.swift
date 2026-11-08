import Foundation

/// A calendar by link (ICS/webcal), read-only. `webcal` becomes `https`;
/// plain HTTP and other schemes are refused.
public struct SubscriptionAdapter: CalendarAdapter {
    let url: URL
    let http: CalendarHTTP

    public init(url: URL, http: CalendarHTTP) throws {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.host?.isEmpty == false else {
            throw CalendarFailure.invalidInput("subscription url")
        }
        switch components.scheme?.lowercased() {
        case "webcal", "webcals", "https": components.scheme = "https"
        default: throw CalendarFailure.invalidInput("subscription url")
        }
        guard let normalized = components.url else { throw CalendarFailure.invalidInput("subscription url") }
        self.url = normalized
        self.http = http
    }

    public var schedulesInvitations: Bool { get async { false } }

    struct Cursor: Codable {
        var etag: String?
        var lastModified: String?
        var ids: [String]
    }

    public func collections() async throws -> [RemoteCollection] {
        [RemoteCollection(externalID: url.absoluteString, name: url.deletingPathExtension().lastPathComponent, color: nil, access: .read)]
    }

    public func changes(collection: CalendarCollection, cursor: Data?, window: DateInterval) async throws -> RemoteChangeSet {
        let previous = cursor.flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) }
        var request = URLRequest(url: url)
        if let etag = previous?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = previous?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await http.send(request, stage: "subscription")
        if response.statusCode == 304 { return RemoteChangeSet(cursor: cursor, full: false) }
        var events = try ICalendar.parse(String(decoding: data, as: UTF8.self), collectionID: collection.id)
        for index in events.indices {
            events[index].externalID = events[index].uid + (events[index].recurrenceID.map { "#" + ICalendar.utc($0) } ?? "")
        }
        let ids = events.compactMap(\.externalID)
        let current = Set(ids)
        let next = Cursor(
            etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"), ids: ids)
        return RemoteChangeSet(
            events: events, removedExternalIDs: (previous?.ids ?? []).filter { !current.contains($0) },
            cursor: try? JSONEncoder().encode(next),
            full: true)
    }

    public func create(_ event: CalendarEvent, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef {
        throw CalendarFailure.invalidInput("read only")
    }
    public func update(
        _ event: CalendarEvent, ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool
    ) async throws
        -> RemoteEventRef
    { throw CalendarFailure.invalidInput("read only") }
    public func delete(ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws {
        throw CalendarFailure.invalidInput("read only")
    }
    public func respond(_ response: CalendarResponse, ref: RemoteEventRef, in collection: CalendarCollection) async throws -> RemoteEventRef
    {
        throw CalendarFailure.invalidInput("read only")
    }
    public func find(uid: String, in collection: CalendarCollection) async throws -> CalendarEvent? { nil }
    public func createBusyCopy(_ copy: DesiredBusyCopy, in collection: CalendarCollection) async throws -> RemoteEventRef {
        throw CalendarFailure.invalidInput("read only")
    }
    public func moveBusyCopy(
        ref: RemoteEventRef, to time: CalendarEventTime, marker: CalendarBusyMarker, in collection: CalendarCollection
    )
        async throws -> RemoteEventRef
    { throw CalendarFailure.invalidInput("read only") }
}
