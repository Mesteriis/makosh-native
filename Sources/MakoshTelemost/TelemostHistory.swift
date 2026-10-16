import Foundation

public struct TelemostLocalMeeting: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: UUID?
    public let validatedURL: TelemostMeetingURL
    public var localTitle: String
    public var notes: String
    public var starred: Bool
    public var hidden: Bool
    public var unavailable: Bool
    public var conference: TelemostConference?
    public var cohosts: [String]
    public var cohostsComplete: Bool
    public var cohostsNextOffset: Int
    public var cohostsPending: [String]
    public var lastCohostPage: TelemostCohostPage?
    public var updatedAt: Date
    public var scope: TelemostScope? { conference?.scope }
    public init(id: UUID = UUID(), accountID: UUID?, validatedURL: TelemostMeetingURL, localTitle: String = "",
                notes: String = "", starred: Bool = false, hidden: Bool = false) {
        self.id = id; self.accountID = accountID; self.validatedURL = validatedURL; self.localTitle = localTitle
        self.notes = notes; self.starred = starred; self.hidden = hidden; unavailable = false
        conference = nil; cohosts = []; cohostsComplete = false; cohostsNextOffset = 0; cohostsPending = []; lastCohostPage = nil; updatedAt = Date()
    }
}
public struct TelemostHistoryCursor: Codable, Sendable {
    public let owner: String
    public let query: String
    public let upper: Int64
    public let before: Int64
}
public struct TelemostMeetingPage: Sendable {
    public let values: [TelemostLocalMeeting]
    public let next: TelemostHistoryCursor?
}
public struct TelemostRetainedVersion: Codable, Sendable {
    public let sequence: Int64
    public let kind: String
    public let payload: Data
}
