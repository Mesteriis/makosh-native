import Foundation

/// A value for a transition or edit field, limited to the types Makosh renders.
public enum JiraFieldValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case date(Date)
    case option(id: String)
    case resolution(id: String)

    var wire: Any {
        switch self {
        case .text(let value): return value
        case .number(let value): return value
        case .date(let value): return JiraDate.dayString(value)
        case .option(let id), .resolution(let id): return ["id": id]
        }
    }
}

/// Which transition fields the card can fill; the rest stay in Jira.
public enum JiraFieldSupport {
    public static let supportedTypes: Set<String> = ["string", "number", "date", "option", "resolution"]

    public static func isSupported(_ field: JiraField) -> Bool { supportedTypes.contains(field.schemaType) }

    public static func unsupportedRequired(_ transition: JiraTransition) -> [JiraField] {
        transition.fields.filter { $0.required && !isSupported($0) }
    }

    /// Throws before any request when a required field cannot be filled from Makosh.
    public static func validate(_ transition: JiraTransition, fields: [String: JiraFieldValue]) throws {
        let blocked = unsupportedRequired(transition).map(\.key)
        guard blocked.isEmpty else { throw JiraAdapterError.unsupportedFields(blocked) }
        let missing = transition.fields.filter { $0.required && fields[$0.key] == nil }.map(\.key)
        guard missing.isEmpty else { throw JiraAdapterError.invalidRequest }
    }
}

/// Fields Makosh may edit on an issue; nil leaves a field alone, `.some(nil)` clears the due date.
public struct JiraIssuePatch: Codable, Equatable, Sendable {
    public var summary: String?
    public var descriptionADF: Data?
    public var priorityID: String?
    public var due: Date??
    public var labels: [String]?

    public init(summary: String? = nil, descriptionADF: Data? = nil, priorityID: String? = nil, due: Date?? = nil, labels: [String]? = nil) {
        self.summary = summary
        self.descriptionADF = descriptionADF
        self.priorityID = priorityID
        self.due = due
        self.labels = labels
    }

    public var isEmpty: Bool { summary == nil && descriptionADF == nil && priorityID == nil && due == nil && labels == nil }

    /// A description is written only over an empty or simple one, so rich formatting is never flattened.
    public func validate(against issue: JiraIssue) throws {
        guard descriptionADF != nil else { return }
        if let current = issue.descriptionADF, !JiraADF.isSimple(current) { throw JiraAdapterError.descriptionNotEditable }
    }

    func wireFields() throws -> [String: Any] {
        var fields: [String: Any] = [:]
        if let summary {
            guard !summary.trimmingCharacters(in: .whitespaces).isEmpty, summary.utf8.count <= 4096 else { throw JiraAdapterError.invalidRequest }
            fields["summary"] = summary
        }
        if let descriptionADF {
            guard let object = try? JSONSerialization.jsonObject(with: descriptionADF) else { throw JiraAdapterError.invalidRequest }
            fields["description"] = object
        }
        if let priorityID { fields["priority"] = ["id": priorityID] }
        if let due { fields["duedate"] = due.map { JiraDate.dayString($0) } ?? NSNull() }
        if let labels { fields["labels"] = labels }
        return fields
    }
}

extension JiraRESTClient {
    func addWorklog(issueID: String, started: Date, seconds: Int, comment: String?) async throws -> String {
        guard Self.identifier(issueID), seconds >= 60, seconds <= 31_536_000 else { throw JiraAdapterError.invalidRequest }
        var body: [String: Any] = ["started": JiraDate.string(started), "timeSpentSeconds": seconds]
        if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let adf = try? JSONSerialization.jsonObject(with: JiraADF.document(fromText: comment))
        {
            body["comment"] = adf
        }
        let created = try await post(JiraWireCreated.self, path: "/issue/\(issueID)/worklog", body: try Self.json(body))
        return created.id.value
    }

    func addComment(issueID: String, body: Data) async throws -> String {
        guard Self.identifier(issueID), let adf = try? JSONSerialization.jsonObject(with: body) else { throw JiraAdapterError.invalidRequest }
        let created = try await post(JiraWireCreated.self, path: "/issue/\(issueID)/comment", body: try Self.json(["body": adf]))
        return created.id.value
    }

    func transition(issueID: String, transitionID: String, fields: [String: JiraFieldValue]) async throws {
        guard Self.identifier(issueID), Self.identifier(transitionID) else { throw JiraAdapterError.invalidRequest }
        var body: [String: Any] = ["transition": ["id": transitionID]]
        if !fields.isEmpty { body["fields"] = fields.mapValues(\.wire) }
        try await send(.post, path: "/issue/\(issueID)/transitions", body: try Self.json(body), expectsNoContent: true)
    }

    func updateFields(issueID: String, patch: JiraIssuePatch) async throws {
        guard Self.identifier(issueID), !patch.isEmpty else { throw JiraAdapterError.invalidRequest }
        try await send(.put, path: "/issue/\(issueID)", body: try Self.json(["fields": try patch.wireFields()]), expectsNoContent: true)
    }

    func assign(issueID: String, accountID: String?) async throws {
        guard Self.identifier(issueID), accountID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true else { throw JiraAdapterError.invalidRequest }
        let body: [String: Any] = ["accountId": accountID ?? NSNull()]
        try await send(.put, path: "/issue/\(issueID)/assignee", body: try Self.json(body), expectsNoContent: true)
    }
}

struct JiraWireCreated: Decodable, Sendable {
    let id: JiraWireID
}

extension JiraAdapter {
    /// Validates the transition's fields against its screen before sending.
    public func transition(_ transition: JiraTransition, issueID: String, fields: [String: JiraFieldValue]) async throws {
        try JiraFieldSupport.validate(transition, fields: fields)
        try await self.transition(issueID: issueID, transitionID: transition.id, fields: fields)
    }
}
