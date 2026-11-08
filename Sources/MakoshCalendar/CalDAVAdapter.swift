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

    public func changes(collection: CalendarCollection, cursor: Data?, window: DateInterval) async throws -> RemoteChangeSet {
        throw CalendarFailure.invalidInput("not implemented")
    }
    public func create(_ event: CalendarEvent, in collection: CalendarCollection, notify: Bool) async throws -> RemoteEventRef {
        throw CalendarFailure.invalidInput("not implemented")
    }
    public func update(
        _ event: CalendarEvent, ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool
    ) async throws
        -> RemoteEventRef
    { throw CalendarFailure.invalidInput("not implemented") }
    public func delete(ref: RemoteEventRef, in collection: CalendarCollection, notify: Bool) async throws {
        throw CalendarFailure.invalidInput("not implemented")
    }
    public func respond(_ response: CalendarResponse, ref: RemoteEventRef, in collection: CalendarCollection) async throws -> RemoteEventRef
    {
        throw CalendarFailure.invalidInput("not implemented")
    }
    public func find(uid: String, in collection: CalendarCollection) async throws -> CalendarEvent? {
        throw CalendarFailure.invalidInput("not implemented")
    }
    public func createBusyCopy(_ copy: DesiredBusyCopy, in collection: CalendarCollection) async throws -> RemoteEventRef {
        throw CalendarFailure.invalidInput("not implemented")
    }
    public func moveBusyCopy(
        ref: RemoteEventRef, to time: CalendarEventTime, marker: CalendarBusyMarker, in collection: CalendarCollection
    )
        async throws -> RemoteEventRef
    { throw CalendarFailure.invalidInput("not implemented") }
}
