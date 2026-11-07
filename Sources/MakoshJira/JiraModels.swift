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
