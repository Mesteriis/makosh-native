import Foundation

/// Jira's status category, the coarse workflow stage every status belongs to.
public enum JiraStatusCategory: String, Codable, Hashable, Sendable {
    case new
    case indeterminate
    case done
    case undefined

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JiraStatusCategory(rawValue: raw) ?? .undefined
    }
}

public struct JiraStatus: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let category: JiraStatusCategory
    public init(id: String, name: String, category: JiraStatusCategory) {
        self.id = id
        self.name = name
        self.category = category
    }
}

public struct JiraUser: Codable, Hashable, Sendable {
    public let accountID: String
    public let displayName: String
    public init(accountID: String, displayName: String) {
        self.accountID = accountID
        self.displayName = displayName
    }
}

public struct JiraPriority: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One issue as Makosh keeps it: wire fields plus a text projection of the description.
public struct JiraIssue: Codable, Equatable, Sendable {
    public let id: String
    public let key: String
    public let projectKey: String
    public var summary: String
    public var descriptionADF: Data?
    public var descriptionText: String
    public var status: JiraStatus
    public var issueType: String
    public var priority: JiraPriority?
    public var assignee: JiraUser?
    public var reporter: JiraUser?
    public var labels: [String]
    public var due: Date?
    public var updated: Date
    public let browseURL: URL

    public init(
        id: String, key: String, projectKey: String, summary: String, descriptionADF: Data? = nil, descriptionText: String = "",
        status: JiraStatus, issueType: String = "Task", priority: JiraPriority? = nil, assignee: JiraUser? = nil,
        reporter: JiraUser? = nil, labels: [String] = [], due: Date? = nil, updated: Date, browseURL: URL
    ) {
        self.id = id
        self.key = key
        self.projectKey = projectKey
        self.summary = summary
        self.descriptionADF = descriptionADF
        self.descriptionText = descriptionText
        self.status = status
        self.issueType = issueType
        self.priority = priority
        self.assignee = assignee
        self.reporter = reporter
        self.labels = labels
        self.due = due
        self.updated = updated
        self.browseURL = browseURL
    }
}

/// One page of a token-paginated listing.
public struct JiraPage<T: Sendable>: Sendable {
    public let items: [T]
    public let nextToken: String?
    public init(items: [T], nextToken: String? = nil) {
        self.items = items
        self.nextToken = nextToken
    }
}

public struct JiraComment: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let author: JiraUser
    public let created: Date
    public let updated: Date
    public let bodyADF: Data
    public let bodyText: String
    public init(id: String, author: JiraUser, created: Date, updated: Date, bodyADF: Data, bodyText: String) {
        self.id = id
        self.author = author
        self.created = created
        self.updated = updated
        self.bodyADF = bodyADF
        self.bodyText = bodyText
    }
}

public struct JiraWorklog: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let author: JiraUser
    public let started: Date
    public let seconds: Int
    public let commentText: String
    public init(id: String, author: JiraUser, started: Date, seconds: Int, commentText: String = "") {
        self.id = id
        self.author = author
        self.started = started
        self.seconds = seconds
        self.commentText = commentText
    }
}

public struct JiraFieldOption: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// A field a transition screen asks for; `schemaType` is Jira's wire type (`string`, `option`, `resolution`, …).
public struct JiraField: Codable, Equatable, Sendable {
    public let key: String
    public let name: String
    public let required: Bool
    public let schemaType: String
    public let allowedValues: [JiraFieldOption]?
    public init(key: String, name: String, required: Bool, schemaType: String, allowedValues: [JiraFieldOption]? = nil) {
        self.key = key
        self.name = name
        self.required = required
        self.schemaType = schemaType
        self.allowedValues = allowedValues
    }
}

public struct JiraTransition: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let to: JiraStatus
    public let fields: [JiraField]
    public init(id: String, name: String, to: JiraStatus, fields: [JiraField] = []) {
        self.id = id
        self.name = name
        self.to = to
        self.fields = fields
    }
}
