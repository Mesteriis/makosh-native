import Foundation
import MakoshGoogle

/// Google Calendar API v3 through the user's OAuth grant. Google sends invitations
/// itself (`sendUpdates`), keeps busy-copy marks in private extended properties
/// and reads changes incrementally with `syncToken`.
public struct GoogleCalendarAdapter: CalendarAdapter {
    static let base = "https://www.googleapis.com/calendar/v3"
    let grant: GoogleGrant
    let oauth: GoogleOAuth
    let http: CalendarHTTP

    public init(grant: GoogleGrant, oauth: GoogleOAuth, http: CalendarHTTP) {
        self.grant = grant
        self.oauth = oauth
        self.http = http
    }

    public var schedulesInvitations: Bool { get async { true } }

    static func segment(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private func request(
        _ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil, etag: String? = nil
    )
        async throws -> URLRequest
    {
        var components = URLComponents(string: Self.base + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        let token = try await CalendarFailure.mapGoogle { try await oauth.accessToken(for: grant) }
        request.setValue("Bearer " + token.value, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        return request
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data, stage: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CalendarFailure.invalidInput(stage) }
    }

    private func encode(_ value: GoogleCalendarMapping.Event) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func events(_ collection: CalendarCollection) -> String { "/calendars/" + Self.segment(collection.externalID) + "/events" }

    public func collections() async throws -> [RemoteCollection] {
        var result: [RemoteCollection] = []
        var page: String?
        repeat {
            let query =
                [URLQueryItem(name: "minAccessRole", value: "reader")] + (page.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let (data, _) = try await http.send(try await request("/users/me/calendarList", query: query), stage: "calendars")
            let list = try decode(GoogleCalendarMapping.CalendarList.self, data, stage: "calendars")
            result += (list.items ?? []).map {
                RemoteCollection(
                    externalID: $0.id, name: $0.summaryOverride ?? $0.summary ?? $0.id, color: $0.backgroundColor,
                    access: ["owner", "writer"].contains($0.accessRole ?? "") ? .write : .read)
            }
            page = list.nextPageToken
        } while page != nil
        return result
    }

    public func changes(collection: CalendarCollection, cursor: Data?, window: DateInterval) async throws -> RemoteChangeSet {
        if let cursor, let token = String(data: cursor, encoding: .utf8), !token.isEmpty {
            do { return try await read(collection, syncToken: token, window: window) } catch CalendarFailure.rejected(code: 410, _) {}
        }
        return try await read(collection, syncToken: nil, window: window)
    }

    private func read(_ collection: CalendarCollection, syncToken: String?, window: DateInterval) async throws -> RemoteChangeSet {
        var result = RemoteChangeSet(cursor: nil, full: syncToken == nil)
        var page: String?
        repeat {
            var query = [
                URLQueryItem(name: "singleEvents", value: "false"), URLQueryItem(name: "showDeleted", value: "true"),
                URLQueryItem(name: "maxResults", value: "250"),
            ]
            if let syncToken {
                query.append(.init(name: "syncToken", value: syncToken))
            } else {
                query.append(
                    .init(name: "timeMin", value: GoogleCalendarMapping.isoPlain.string(from: window.start.addingTimeInterval(-30 * 86400)))
                )
            }
            if let page { query.append(.init(name: "pageToken", value: page)) }
            let (data, _) = try await http.send(try await request(events(collection), query: query), stage: "events")
            let decoded = try decode(GoogleCalendarMapping.Page.self, data, stage: "events")
            for item in decoded.items ?? [] {
                if item.status == "cancelled", item.recurringEventId == nil {
                    if let id = item.id { result.removedExternalIDs.append(id) }
                    continue
                }
                guard let event = GoogleCalendarMapping.event(item, collectionID: collection.id) else { continue }
                result.events.append(event)
                if let marker = event.busyMarker, let id = event.externalID {
                    result.busyCopies.append(
                        ObservedBusyCopy(externalID: id, marker: marker, time: event.time, collectionID: collection.id))
                }
            }
            page = decoded.nextPageToken
            if page == nil { result.cursor = decoded.nextSyncToken.map { Data($0.utf8) } }
        } while page != nil
        return result
    }

    private func write(_ request: URLRequest, stage: String) async throws -> RemoteEventRef {
        let (data, _) = try await http.send(request, stage: stage)
        let item = try decode(GoogleCalendarMapping.Event.self, data, stage: stage)
        guard let id = item.id else { throw CalendarFailure.invalidInput(stage) }
        return RemoteEventRef(externalID: id, etag: item.etag)
    }

    private func updates(_ notify: Bool) -> [URLQueryItem] { [URLQueryItem(name: "sendUpdates", value: notify ? "all" : "none")] }

    public func create(_ event: CalendarEvent, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef {
        var body = GoogleCalendarMapping.body(event)
        body.iCalUID = event.uid
        return try await write(
            try await request(events(collection), query: updates(notify), method: "POST", body: try encode(body)), stage: "create")
    }

    public func update(
        _ event: CalendarEvent, ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool
    ) async throws
        -> RemoteEventRef
    {
        try await write(
            try await request(
                events(collection) + "/" + Self.segment(ref.externalID), query: updates(notify), method: "PATCH",
                body: try encode(GoogleCalendarMapping.body(event)), etag: ref.etag), stage: "update")
    }

    public func delete(ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws {
        do {
            _ = try await http.send(
                try await request(
                    events(collection) + "/" + Self.segment(ref.externalID), query: updates(notify), method: "DELETE", etag: ref.etag),
                stage: "delete")
        } catch CalendarFailure.rejected(code: 410, _) {
            // Already gone.
        }
    }

    public func respond(_ response: CalendarResponse, ref: RemoteEventRef, in collection: CalendarCollection) async throws -> RemoteEventRef
    {
        let path = events(collection) + "/" + Self.segment(ref.externalID)
        let (data, _) = try await http.send(try await request(path), stage: "respond")
        let current = try decode(GoogleCalendarMapping.Event.self, data, stage: "respond")
        guard var attendees = current.attendees, let index = attendees.firstIndex(where: { $0.isSelf == true }) else {
            throw CalendarFailure.invalidInput("not invited")
        }
        attendees[index].responseStatus = GoogleCalendarMapping.responseText(response)
        struct Patch: Encodable { let attendees: [GoogleCalendarMapping.Attendee] }
        let body = try JSONEncoder().encode(Patch(attendees: attendees))
        return try await write(
            try await request(path, query: updates(true), method: "PATCH", body: body, etag: current.etag ?? ref.etag), stage: "respond")
    }

    public func find(uid: String, in collection: CalendarCollection) async throws -> CalendarEvent? {
        let query = [URLQueryItem(name: "iCalUID", value: uid), URLQueryItem(name: "showDeleted", value: "false")]
        let (data, _) = try await http.send(try await request(events(collection), query: query), stage: "find")
        let page = try decode(GoogleCalendarMapping.Page.self, data, stage: "find")
        return (page.items ?? []).filter { $0.iCalUID == uid && $0.recurringEventId == nil && $0.status != "cancelled" }
            .compactMap { GoogleCalendarMapping.event($0, collectionID: collection.id) }.first
    }

    public func createBusyCopy(_ copy: DesiredBusyCopy, in collection: CalendarCollection) async throws -> RemoteEventRef {
        let body = try encode(GoogleCalendarMapping.busyBody(time: copy.time, marker: copy.marker))
        return try await write(
            try await request(events(collection), query: updates(false), method: "POST", body: Self.privateVisibility(body)), stage: "copy")
    }

    public func moveBusyCopy(
        ref: RemoteEventRef, to time: CalendarEventTime, marker: CalendarBusyMarker, in collection: CalendarCollection
    )
        async throws -> RemoteEventRef
    {
        let body = try encode(GoogleCalendarMapping.busyBody(time: time, marker: marker))
        return try await write(
            try await request(
                events(collection) + "/" + Self.segment(ref.externalID), query: updates(false), method: "PATCH",
                body: Self.privateVisibility(body)), stage: "copy")
    }

    /// `visibility` is not part of the read model; it is set on every busy copy.
    static func privateVisibility(_ body: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
        object["visibility"] = "private"
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? body
    }
}
