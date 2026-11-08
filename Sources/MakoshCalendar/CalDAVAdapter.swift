import Foundation

/// RFC 4791 CalDAV with Basic authentication over HTTPS only (Yandex, iCloud,
/// Fastmail…). Discovery is cached for the adapter's lifetime.
public actor CalDAVAdapter: CalendarAdapter {
    let server: URL
    let login: String
    let password: String
    let http: CalendarHTTP
    private var discovered: (principal: URL, home: URL, schedules: Bool)?

    public init(server: URL, login: String, password: String, http: CalendarHTTP) {
        self.server = server
        self.login = login
        self.password = password
        self.http = http
    }

    public var schedulesInvitations: Bool {
        get async { (try? await discovery().schedules) ?? false }
    }

    static func authorization(_ login: String, _ password: String) -> String {
        "Basic " + Data((login + ":" + password).utf8).base64EncodedString()
    }

    static func dav(
        _ url: URL, method: String, depth: String? = nil, body: String? = nil, login: String, password: String,
        headers: [String: String] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorization(login, password), forHTTPHeaderField: "Authorization")
        if let depth { request.setValue(depth, forHTTPHeaderField: "Depth") }
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    static func propfind(_ props: String) -> String {
        #"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/"><d:prop>"#
            + props + "</d:prop></d:propfind>"
    }

    public static func probe(
        server: URL, login: String, password: String, http: CalendarHTTP
    ) async throws
        -> (principal: URL, home: URL, schedules: Bool)
    {
        guard server.scheme == "https", server.host != nil else { throw CalendarFailure.invalidInput("https required") }
        let principalBody = propfind("<d:current-user-principal/>")
        var principal: URL?
        for candidate in [server.appendingPathComponent(".well-known/caldav"), server] {
            guard
                let (data, response) = try? await http.send(
                    dav(candidate, method: "PROPFIND", depth: "0", body: principalBody, login: login, password: password), stage: "discover"
                )
            else { continue }
            let base = response.url ?? candidate
            if let href = try CalDAVNode.responses(data).compactMap({ $0.props.child("current-user-principal")?.child("href")?.trimmed })
                .first,
                let url = URL(string: href, relativeTo: base)?.absoluteURL
            {
                principal = url
                break
            }
        }
        guard let principal, principal.host == server.host else { throw CalendarFailure.rejected(code: 404, stage: "discover") }
        let (homeData, _) = try await http.send(
            dav(principal, method: "PROPFIND", depth: "0", body: propfind("<c:calendar-home-set/>"), login: login, password: password),
            stage: "discover")
        guard
            let href = try CalDAVNode.responses(homeData).compactMap({
                $0.props.child("calendar-home-set", CalDAVNode.caldav)?.child("href")?.trimmed
            }).first, let home = URL(string: href, relativeTo: principal)?.absoluteURL, home.host == server.host
        else { throw CalendarFailure.rejected(code: 404, stage: "discover") }
        let (_, options) = try await http.send(dav(home, method: "OPTIONS", login: login, password: password), stage: "discover")
        let schedules = (options.value(forHTTPHeaderField: "DAV") ?? "").lowercased().split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "calendar-auto-schedule" }
        return (principal, home, schedules)
    }

    func discovery() async throws -> (principal: URL, home: URL, schedules: Bool) {
        if let discovered { return discovered }
        let value = try await Self.probe(server: server, login: login, password: password, http: http)
        discovered = value
        return value
    }

    func request(_ url: URL, method: String, depth: String? = nil, body: String? = nil, headers: [String: String] = [:]) -> URLRequest {
        Self.dav(url, method: method, depth: depth, body: body, login: login, password: password, headers: headers)
    }

    public func collections() async throws -> [RemoteCollection] {
        let home = try await discovery().home
        let body = Self.propfind(
            "<d:resourcetype/><d:displayname/><a:calendar-color/><d:current-user-privilege-set/><c:supported-calendar-component-set/><d:sync-token/>"
        )
        let (data, _) = try await http.send(request(home, method: "PROPFIND", depth: "1", body: body), stage: "calendars")
        return try CalDAVNode.responses(data).compactMap { response in
            guard response.props.child("resourcetype")?.child("calendar", CalDAVNode.caldav) != nil,
                let url = URL(string: response.href, relativeTo: home)?.absoluteURL, url.host == server.host
            else { return nil }
            if let components = response.props.child("supported-calendar-component-set", CalDAVNode.caldav) {
                guard components.all("comp", CalDAVNode.caldav).contains(where: { $0.attributes["name"]?.uppercased() == "VEVENT" }) else {
                    return nil
                }
            }
            let privileges = Set(
                response.props.child("current-user-privilege-set")?.descendants("privilege").flatMap { $0.children.map(\.name) } ?? [])
            let writable = !privileges.isDisjoint(with: ["write", "write-content", "all"])
            var color = response.props.child("calendar-color", CalDAVNode.apple)?.trimmed
            if let value = color, value.count == 9, value.hasPrefix("#") { color = String(value.prefix(7)) }
            return RemoteCollection(
                externalID: url.absoluteString, name: response.props.child("displayname")?.trimmed ?? url.lastPathComponent, color: color,
                access: writable ? .write : .read)
        }
    }

    // MARK: Reading

    static func collectionURL(_ collection: CalendarCollection) throws -> URL {
        guard let url = URL(string: collection.externalID), url.scheme == "https" else { throw CalendarFailure.invalidInput("collection") }
        return url
    }

    public func changes(collection: CalendarCollection, cursor: Data?, window: DateInterval) async throws -> RemoteChangeSet {
        let url = try Self.collectionURL(collection)
        switch CalDAVCursor(data: cursor) {
        case .etags(let previous)?:
            return try await etagDiff(collection, url: url, previous: previous, window: window, full: false)
        case .token(let token)?:
            do {
                return try await syncCollection(collection, url: url, token: token, full: false)
            } catch CalendarFailure.rejected(let code, _) where [400, 403, 409].contains(code) {
                return try await syncCollection(collection, url: url, token: "", full: true)
            }
        case nil:
            do {
                return try await syncCollection(collection, url: url, token: "", full: true)
            } catch CalendarFailure.rejected(let code, _) where [400, 403, 405, 409, 501].contains(code) {
                return try await etagDiff(collection, url: url, previous: [:], window: window, full: true)
            }
        }
    }

    private func syncCollection(_ collection: CalendarCollection, url: URL, token: String, full: Bool) async throws -> RemoteChangeSet {
        let body =
            #"<?xml version="1.0" encoding="utf-8"?><d:sync-collection xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">"#
            + "<d:sync-token>\(token.xmlEscaped)</d:sync-token><d:sync-level>1</d:sync-level><d:prop><d:getetag/><c:calendar-data/></d:prop></d:sync-collection>"
        let (data, _) = try await http.send(request(url, method: "REPORT", depth: "1", body: body), stage: "sync")
        let root = try CalDAVNode.parse(data)
        let newToken = root.child("sync-token")?.trimmed
        var result = RemoteChangeSet(cursor: newToken.map { CalDAVCursor.token($0).data }, full: full)
        var missing: [URL] = []
        for response in try CalDAVNode.responses(data) {
            guard let href = URL(string: response.href, relativeTo: url)?.absoluteURL, href.host == url.host, href != url else { continue }
            if response.status?.contains(" 404 ") == true {
                result.removedExternalIDs.append(href.absoluteString)
                continue
            }
            let etag = response.props.child("getetag")?.trimmed
            if let text = response.props.child("calendar-data", CalDAVNode.caldav)?.text, !text.isEmpty {
                try append(text, href: href, etag: etag, collection: collection, into: &result)
            } else {
                missing.append(href)
            }
        }
        if !missing.isEmpty { try await multiget(missing, collection: collection, url: url, into: &result) }
        return result
    }

    private func etagDiff(
        _ collection: CalendarCollection, url: URL, previous: [String: String], window: DateInterval, full: Bool
    )
        async throws -> RemoteChangeSet
    {
        // The whole calendar, not a time range: an event that merely aged out of a range is not gone.
        let body =
            #"<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/></d:prop>"#
            + #"<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"/></c:comp-filter></c:filter></c:calendar-query>"#
        let (data, _) = try await http.send(request(url, method: "REPORT", depth: "1", body: body), stage: "query")
        var current: [String: String] = [:]
        for response in try CalDAVNode.responses(data) {
            guard let href = URL(string: response.href, relativeTo: url)?.absoluteURL, href.host == url.host, href != url,
                let etag = response.props.child("getetag")?.trimmed
            else { continue }
            current[href.absoluteString] = etag
        }
        var result = RemoteChangeSet(cursor: CalDAVCursor.etags(current).data, full: full)
        result.removedExternalIDs = previous.keys.filter { current[$0] == nil }.sorted()
        let changed = current.filter { previous[$0.key] != $0.value }.keys.sorted().compactMap(URL.init(string:))
        if !changed.isEmpty { try await multiget(changed, collection: collection, url: url, into: &result) }
        return result
    }

    private func multiget(_ hrefs: [URL], collection: CalendarCollection, url: URL, into result: inout RemoteChangeSet) async throws {
        for chunk in stride(from: 0, to: hrefs.count, by: 100).map({ Array(hrefs[$0..<min($0 + 100, hrefs.count)]) }) {
            let body =
                #"<?xml version="1.0" encoding="utf-8"?><c:calendar-multiget xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop>"#
                + chunk.map { "<d:href>\($0.path.xmlEscaped)</d:href>" }.joined() + "</c:calendar-multiget>"
            let (data, _) = try await http.send(request(url, method: "REPORT", depth: "1", body: body), stage: "multiget")
            for response in try CalDAVNode.responses(data) {
                guard let href = URL(string: response.href, relativeTo: url)?.absoluteURL, href.host == url.host,
                    let text = response.props.child("calendar-data", CalDAVNode.caldav)?.text, !text.isEmpty
                else { continue }
                try append(text, href: href, etag: response.props.child("getetag")?.trimmed, collection: collection, into: &result)
            }
        }
    }

    /// One resource may hold a series and its overrides: the master keeps the
    /// resource URL as its id, each override gets `<url>#<recurrence id>`.
    private func append(_ text: String, href: URL, etag: String?, collection: CalendarCollection, into result: inout RemoteChangeSet) throws
    {
        for var event in try ICalendar.parse(text, collectionID: collection.id) {
            event.externalID = href.absoluteString + (event.recurrenceID.map { "#" + ICalendar.utc($0) } ?? "")
            event.etag = etag
            for index in event.attendees.indices where event.attendees[index].email.caseInsensitiveCompare(login) == .orderedSame {
                event.attendees[index].isSelf = true
            }
            result.events.append(event)
            if let marker = event.busyMarker, let id = event.externalID {
                result.busyCopies.append(ObservedBusyCopy(externalID: id, marker: marker, time: event.time, collectionID: collection.id))
            }
        }
    }

    // MARK: Writing

    private func put(_ url: URL, ics: String, etag: String?, create: Bool, stage: String) async throws -> RemoteEventRef {
        var headers = ["Content-Type": "text/calendar; charset=utf-8"]
        if create { headers["If-None-Match"] = "*" } else if let etag { headers["If-Match"] = etag }
        var put = request(url, method: "PUT", headers: headers)
        put.httpBody = Data(ics.utf8)
        let (_, response) = try await http.send(put, stage: stage)
        return RemoteEventRef(externalID: url.absoluteString, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    private func prepared(_ event: CalendarEvent) async throws -> CalendarEvent {
        var event = event
        let schedules = try await discovery().schedules
        if event.attendees.isEmpty || !schedules {
            event.attendees = []
            event.organizerEmail = nil
        } else {
            event.organizerEmail = event.organizerEmail ?? login
        }
        return event
    }

    public func create(_ event: CalendarEvent, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef {
        let url = try Self.collectionURL(collection).appendingPathComponent(UUID().uuidString.lowercased() + ".ics")
        return try await put(url, ics: ICalendar.serialize(try await prepared(event)), etag: nil, create: true, stage: "create")
    }

    /// An edit rewrites the resource from what the server holds: overrides stay (except
    /// occurrences now excluded), and an invitation someone else organizes keeps its attendees.
    public func update(
        _ event: CalendarEvent, ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool
    ) async throws
        -> RemoteEventRef
    {
        guard let url = URL(string: ref.externalID.components(separatedBy: "#")[0]) else { throw CalendarFailure.invalidInput("href") }
        let (data, reply) = try await http.send(request(url, method: "GET"), stage: "update")
        let current = try ICalendar.parse(String(decoding: data, as: UTF8.self), collectionID: collection.id)
        let currentMaster = current.first { $0.recurrenceID == nil }
        var master = event.recurrenceID == nil ? event : (currentMaster ?? event)
        var overrides = current.filter { $0.recurrenceID != nil }
        if let changed = event.recurrenceID {
            overrides.removeAll { $0.recurrenceID == changed }
            overrides.append(event)
        }
        let excluded = Set(master.recurrence?.exdates ?? [])
        overrides.removeAll { $0.recurrenceID.map(excluded.contains) == true }
        if let organizer = currentMaster?.organizerEmail, organizer.caseInsensitiveCompare(login) != .orderedSame {
            master.organizerEmail = organizer
            master.attendees = currentMaster?.attendees ?? master.attendees
        } else {
            master = try await prepared(master)
        }
        return try await put(
            url, ics: ICalendar.serialize(master, overrides: overrides), etag: reply.value(forHTTPHeaderField: "ETag") ?? ref.etag,
            create: false,
            stage: "update")
    }

    public func delete(ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws {
        guard let url = URL(string: ref.externalID.components(separatedBy: "#")[0]) else { throw CalendarFailure.invalidInput("href") }
        do {
            _ = try await http.send(request(url, method: "DELETE", headers: ref.etag.map { ["If-Match": $0] } ?? [:]), stage: "delete")
        } catch CalendarFailure.rejected(code: 404, _) {
            // Already gone.
        }
    }

    public func respond(_ response: CalendarResponse, ref: RemoteEventRef, in collection: CalendarCollection) async throws -> RemoteEventRef
    {
        guard let url = URL(string: ref.externalID.components(separatedBy: "#")[0]) else { throw CalendarFailure.invalidInput("href") }
        let (data, reply) = try await http.send(request(url, method: "GET"), stage: "respond")
        var events = try ICalendar.parse(String(decoding: data, as: UTF8.self), collectionID: collection.id)
        var changed = false
        for e in events.indices {
            for a in events[e].attendees.indices where events[e].attendees[a].email.caseInsensitiveCompare(login) == .orderedSame {
                events[e].attendees[a].response = response
                changed = true
            }
        }
        guard changed, let master = events.first(where: { $0.recurrenceID == nil }) ?? events.first else {
            throw CalendarFailure.invalidInput("not invited")
        }
        let overrides = events.filter { $0.id != master.id }
        return try await put(
            url, ics: ICalendar.serialize(master, overrides: overrides), etag: reply.value(forHTTPHeaderField: "ETag") ?? ref.etag,
            create: false,
            stage: "respond")
    }

    public func find(uid: String, in collection: CalendarCollection) async throws -> CalendarEvent? {
        let url = try Self.collectionURL(collection)
        let body =
            #"<?xml version="1.0" encoding="utf-8"?><c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop>"#
            + #"<c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VEVENT"><c:prop-filter name="UID"><c:text-match collation="i;octet">"#
            + uid.xmlEscaped + "</c:text-match></c:prop-filter></c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"
        let (data, _) = try await http.send(request(url, method: "REPORT", depth: "1", body: body), stage: "find")
        var result = RemoteChangeSet(cursor: nil, full: false)
        for response in try CalDAVNode.responses(data) {
            guard let href = URL(string: response.href, relativeTo: url)?.absoluteURL,
                let text = response.props.child("calendar-data", CalDAVNode.caldav)?.text
            else { continue }
            try append(text, href: href, etag: response.props.child("getetag")?.trimmed, collection: collection, into: &result)
        }
        return result.events.first { $0.uid == uid && $0.recurrenceID == nil }
    }

    static func busyUID(_ marker: CalendarBusyMarker) -> String {
        "makosh-busy-" + marker.sourceEventID.uuidString.lowercased() + "-" + String(Int(marker.occurrenceStart.timeIntervalSince1970))
    }

    public func createBusyCopy(_ copy: DesiredBusyCopy, in collection: CalendarCollection) async throws -> RemoteEventRef {
        let uid = Self.busyUID(copy.marker)
        let url = try Self.collectionURL(collection).appendingPathComponent(uid + ".ics")
        return try await put(
            url, ics: ICalendar.serializeBusyCopy(uid: uid, time: copy.time, marker: copy.marker), etag: nil, create: true, stage: "copy")
    }

    public func moveBusyCopy(
        ref: RemoteEventRef, to time: CalendarEventTime, marker: CalendarBusyMarker, in collection: CalendarCollection
    )
        async throws -> RemoteEventRef
    {
        guard let url = URL(string: ref.externalID) else { throw CalendarFailure.invalidInput("href") }
        return try await put(
            url, ics: ICalendar.serializeBusyCopy(uid: Self.busyUID(marker), time: time, marker: marker), etag: ref.etag, create: false,
            stage: "copy")
    }
}

/// Where the last CalDAV read stopped: a sync token, or the ETags of every resource.
enum CalDAVCursor: Codable, Equatable {
    case token(String)
    case etags([String: String])

    init?(data: Data?) {
        guard let data, let value = try? JSONDecoder().decode(CalDAVCursor.self, from: data) else { return nil }
        self = value
    }
    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
