import Foundation

// The REST v3 client written for Makosh; wire structs follow MacTower's
// `JiraResponseParsing.swift` (317eeaf) in spirit: tolerant ids, strict dates.

struct JiraRESTClient: Sendable {
    let transport: JiraTransport
    static let root = "/rest/api/3"
    static let issueFields = "summary,description,status,issuetype,priority,assignee,reporter,labels,duedate,updated,project"

    func get<T: Decodable & Sendable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        try decode(type, try await transport.send(JiraRequest(path: Self.root + path, query: query)))
    }

    func post<T: Decodable & Sendable>(_ type: T.Type, path: String, body: Data) async throws -> T {
        try decode(type, try await transport.send(JiraRequest(path: Self.root + path, method: .post, body: body)))
    }

    func send(_ method: JiraRequest.Method, path: String, body: Data?, expectsNoContent: Bool) async throws {
        _ = try await transport.send(JiraRequest(path: Self.root + path, method: method, body: body, expectsNoContent: expectsNoContent))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw JiraAdapterError.invalidResponse }
    }

    static func json(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw JiraAdapterError.invalidRequest }
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.wholeMatch(of: /[A-Za-z0-9_-]+/) != nil
    }

    // MARK: Reads

    func currentUser() async throws -> JiraUser {
        try await get(JiraWireUser.self, path: "/myself").normalized()
    }

    func searchIssues(jql: String, nextToken: String?, limit: Int) async throws -> JiraPage<JiraIssue> {
        var body: [String: Any] = [
            "jql": jql, "maxResults": max(1, min(limit, 100)), "fields": Self.issueFields.split(separator: ",").map(String.init),
        ]
        if let nextToken { body["nextPageToken"] = nextToken }
        let envelope = try await post(JiraSearchEnvelope.self, path: "/search/jql", body: try Self.json(body))
        let issues = try envelope.issues.map { try $0.normalized(origin: transport.origin) }
        return JiraPage(items: issues, nextToken: envelope.isLast == true ? nil : envelope.nextPageToken)
    }

    func issue(id: String) async throws -> JiraIssue {
        guard Self.identifier(id) else { throw JiraAdapterError.invalidRequest }
        return try await get(JiraWireIssue.self, path: "/issue/\(id)", query: [URLQueryItem(name: "fields", value: Self.issueFields)])
            .normalized(origin: transport.origin)
    }

    func transitions(issueID: String) async throws -> [JiraTransition] {
        guard Self.identifier(issueID) else { throw JiraAdapterError.invalidRequest }
        let envelope = try await get(
            JiraTransitionEnvelope.self, path: "/issue/\(issueID)/transitions", query: [URLQueryItem(name: "expand", value: "transitions.fields")])
        guard envelope.transitions.count <= 100 else { throw JiraAdapterError.invalidResponse }
        return try envelope.transitions.filter { $0.isAvailable != false }.map { try $0.normalized() }
    }

    func comments(issueID: String, nextToken: String?) async throws -> JiraPage<JiraComment> {
        guard Self.identifier(issueID) else { throw JiraAdapterError.invalidRequest }
        let start = nextToken.flatMap(Int.init) ?? 0
        let envelope = try await get(
            JiraCommentEnvelope.self, path: "/issue/\(issueID)/comment",
            query: [
                URLQueryItem(name: "startAt", value: String(start)), URLQueryItem(name: "maxResults", value: "50"),
                URLQueryItem(name: "orderBy", value: "created"),
            ])
        let items = try envelope.comments.map { try $0.normalized() }
        let next = envelope.startAt + envelope.comments.count
        return JiraPage(items: items, nextToken: next < envelope.total && !envelope.comments.isEmpty ? String(next) : nil)
    }

    func worklogs(issueID: String) async throws -> [JiraWorklog] {
        guard Self.identifier(issueID) else { throw JiraAdapterError.invalidRequest }
        var start = 0
        var result: [JiraWorklog] = []
        for _ in 0..<20 {
            let envelope = try await get(
                JiraWorklogEnvelope.self, path: "/issue/\(issueID)/worklog",
                query: [URLQueryItem(name: "startAt", value: String(start)), URLQueryItem(name: "maxResults", value: "1000")])
            result += try envelope.worklogs.map { try $0.normalized() }
            start = envelope.startAt + envelope.worklogs.count
            if envelope.worklogs.isEmpty || start >= envelope.total { break }
        }
        return result
    }

    func projectStatuses(projectKey: String) async throws -> [JiraStatus] {
        guard Self.identifier(projectKey) else { throw JiraAdapterError.invalidRequest }
        let types = try await get([JiraWireProjectStatuses].self, path: "/project/\(projectKey)/statuses")
        var seen: Set<String> = []
        var result: [JiraStatus] = []
        for type in types {
            for status in type.statuses {
                let value = try status.normalized()
                if seen.insert(value.id).inserted { result.append(value) }
            }
        }
        return result
    }

    func priorities() async throws -> [JiraPriority] {
        try await get([JiraWirePriority].self, path: "/priority").map { JiraPriority(id: $0.id.value, name: $0.name) }
    }

    func assignableUsers(projectKey: String, query: String) async throws -> [JiraUser] {
        guard Self.identifier(projectKey), query.utf8.count <= 256 else { throw JiraAdapterError.invalidRequest }
        let users = try await get(
            [JiraWireUser].self, path: "/user/assignable/search",
            query: [
                URLQueryItem(name: "project", value: projectKey), URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "maxResults", value: "50"),
            ])
        return try users.map { try $0.normalized() }
    }
}

// MARK: - Wire shapes

struct JiraWireID: Decodable, Sendable {
    let value: String
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) { value = string } else { value = String(try container.decode(Int64.self)) }
        guard JiraRESTClient.identifier(value) else { throw JiraAdapterError.invalidResponse }
    }
}

struct JiraWireUser: Decodable, Sendable {
    let accountId: String?
    let displayName: String?
    func normalized() throws -> JiraUser {
        guard let accountId, JiraRESTClient.identifier(accountId.replacingOccurrences(of: ":", with: "-")),
            displayName.map({ $0.utf8.count <= 512 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) ?? true
        else { throw JiraAdapterError.invalidResponse }
        return JiraUser(accountID: accountId, displayName: displayName ?? accountId)
    }
}

struct JiraWireStatus: Decodable, Sendable {
    struct Category: Decodable, Sendable { let key: String? }
    let id: JiraWireID
    let name: String
    let statusCategory: Category?
    func normalized() throws -> JiraStatus {
        guard JiraWire.validText(name, limit: 512) else { throw JiraAdapterError.invalidResponse }
        return JiraStatus(id: id.value, name: name, category: JiraStatusCategory(rawValue: statusCategory?.key ?? "") ?? .undefined)
    }
}

struct JiraWirePriority: Decodable, Sendable {
    let id: JiraWireID
    let name: String
}

enum JiraWire {
    static func validText(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
    /// A raw JSON subtree kept as data, or nil for JSON null / absence.
    struct RawJSON: Decodable, Sendable {
        let data: Data?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                data = nil
                return
            }
            let value = try container.decode(AnyJSON.self)
            data = try JSONSerialization.data(withJSONObject: value.object, options: [.sortedKeys])
        }
    }
    /// Enough of JSON to re-serialize an ADF subtree byte-for-byte in content.
    struct AnyJSON: Decodable {
        let object: Any
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { object = NSNull() } else if let value = try? container.decode(Bool.self) { object = value } else if let value =
                try? container.decode(Int64.self)
            {
                object = value
            } else if let value = try? container.decode(Double.self) {
                object = value
            } else if let value = try? container.decode(String.self) {
                object = value
            } else if let value = try? container.decode([AnyJSON].self) {
                object = value.map(\.object)
            } else if let value = try? container.decode([String: AnyJSON].self) {
                object = value.mapValues(\.object)
            } else {
                throw JiraAdapterError.invalidResponse
            }
        }
    }
}

struct JiraWireIssue: Decodable, Sendable {
    struct Fields: Decodable, Sendable {
        struct Project: Decodable, Sendable { let key: String }
        struct IssueType: Decodable, Sendable { let name: String? }
        let summary: String?
        let description: JiraWire.RawJSON?
        let status: JiraWireStatus
        let issuetype: IssueType?
        let priority: JiraWirePriority?
        let assignee: JiraWireUser?
        let reporter: JiraWireUser?
        let labels: [String]?
        let duedate: String?
        let updated: String
        let project: Project
    }
    let id: JiraWireID
    let key: String
    let fields: Fields

    func normalized(origin: URL) throws -> JiraIssue {
        guard JiraRESTClient.identifier(key), JiraRESTClient.identifier(fields.project.key), let updated = JiraDate.parse(fields.updated),
            fields.summary.map({ $0.utf8.count <= 4096 && !$0.contains("\0") }) ?? true
        else { throw JiraAdapterError.invalidResponse }
        let description = fields.description?.data
        var browse = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        browse.path = "/browse/\(key)"
        return JiraIssue(
            id: id.value, key: key, projectKey: fields.project.key, summary: fields.summary ?? "", descriptionADF: description,
            descriptionText: description.map(JiraADF.text(from:)) ?? "", status: try fields.status.normalized(),
            issueType: fields.issuetype?.name ?? "", priority: fields.priority.map { JiraPriority(id: $0.id.value, name: $0.name) },
            assignee: try fields.assignee?.normalized(), reporter: try fields.reporter?.normalized(), labels: fields.labels ?? [],
            due: fields.duedate.flatMap(JiraDate.parseDay), updated: updated, browseURL: browse.url ?? origin)
    }
}

struct JiraSearchEnvelope: Decodable, Sendable {
    let isLast: Bool?
    let nextPageToken: String?
    let issues: [JiraWireIssue]
}

struct JiraTransitionEnvelope: Decodable, Sendable {
    struct Transition: Decodable, Sendable {
        struct Field: Decodable, Sendable {
            struct Schema: Decodable, Sendable {
                let type: String?
                let custom: String?
            }
            struct Value: Decodable, Sendable {
                let id: JiraWireID?
                let name: String?
                let value: String?
            }
            let required: Bool
            let name: String?
            let schema: Schema?
            let allowedValues: [Value]?
        }
        let id: JiraWireID
        let name: String
        let to: JiraWireStatus
        let fields: [String: Field]?
        let isAvailable: Bool?

        func normalized() throws -> JiraTransition {
            guard JiraWire.validText(name, limit: 512), (fields?.count ?? 0) <= 256 else { throw JiraAdapterError.invalidResponse }
            let fields = (fields ?? [:]).map { key, field in
                JiraField(
                    key: key, name: field.name ?? key, required: field.required, schemaType: field.schema?.type ?? "unknown",
                    allowedValues: field.allowedValues?.compactMap { value in
                        value.id.map { JiraFieldOption(id: $0.value, name: value.name ?? value.value ?? $0.value) }
                    })
            }.sorted { $0.key < $1.key }
            return JiraTransition(id: id.value, name: name, to: try to.normalized(), fields: fields)
        }
    }
    let transitions: [Transition]
}

struct JiraWireComment: Decodable, Sendable {
    let id: JiraWireID
    let author: JiraWireUser
    let created: String
    let updated: String
    let body: JiraWire.RawJSON?
    func normalized() throws -> JiraComment {
        guard let created = JiraDate.parse(created), let updated = JiraDate.parse(updated) else { throw JiraAdapterError.invalidResponse }
        let adf = body?.data ?? Data("{}".utf8)
        return JiraComment(id: id.value, author: try author.normalized(), created: created, updated: updated, bodyADF: adf, bodyText: JiraADF.text(from: adf))
    }
}

struct JiraCommentEnvelope: Decodable, Sendable {
    let startAt: Int
    let total: Int
    let comments: [JiraWireComment]
}

struct JiraWireWorklog: Decodable, Sendable {
    let id: JiraWireID
    let author: JiraWireUser
    let started: String
    let timeSpentSeconds: Int
    let comment: JiraWire.RawJSON?
    func normalized() throws -> JiraWorklog {
        guard let started = JiraDate.parse(started), (0...31_536_000_000).contains(timeSpentSeconds) else {
            throw JiraAdapterError.invalidResponse
        }
        return JiraWorklog(
            id: id.value, author: try author.normalized(), started: started, seconds: timeSpentSeconds,
            commentText: comment?.data.map(JiraADF.text(from:)) ?? "")
    }
}

struct JiraWorklogEnvelope: Decodable, Sendable {
    let startAt: Int
    let total: Int
    let worklogs: [JiraWireWorklog]
}

struct JiraWireProjectStatuses: Decodable, Sendable {
    let statuses: [JiraWireStatus]
}

// Transferred from MacTower `JiraResponseParsing.swift` (317eeaf): strict Jira timestamps.
enum JiraDate {
    static func parse(_ string: String) -> Date? {
        guard string.utf8.count <= 40,
            string.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?(Z|[+-][0-9]{2}:?[0-9]{2})/) != nil
        else { return nil }
        var value = string
        if value.hasSuffix("Z") { value = String(value.dropLast()) + "+0000" }
        if value.suffix(6).contains(":") { value.remove(at: value.index(value.endIndex, offsetBy: -3)) }
        let formatter = formatter(fractional: value.contains("."))
        guard let result = formatter.date(from: value) else { return nil }
        let offset = String(value.suffix(5))
        guard let hours = Int(offset.dropFirst().prefix(2)), let minutes = Int(offset.suffix(2)), hours <= 23, minutes <= 59,
            let timeZone = TimeZone(secondsFromGMT: (hours * 3600 + minutes * 60) * (offset.first == "-" ? -1 : 1))
        else { return nil }
        formatter.timeZone = timeZone
        guard formatter.string(from: result) == value else { return nil }
        return result
    }

    /// Jira's wire format for timestamps it accepts: `yyyy-MM-dd'T'HH:mm:ss.SSSZ`.
    static func string(_ date: Date) -> String { formatter(fractional: true).string(from: date) }

    /// A `yyyy-MM-dd` field as UTC midnight.
    static func parseDay(_ string: String) -> Date? {
        guard string.wholeMatch(of: /[0-9]{4}-[0-9]{2}-[0-9]{2}/) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: string)
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func formatter(fractional: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = fractional ? "yyyy-MM-dd'T'HH:mm:ss.SSSZ" : "yyyy-MM-dd'T'HH:mm:ssZ"
        formatter.isLenient = false
        return formatter
    }
}
