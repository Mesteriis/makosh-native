import Foundation

/// Issue keys inside a meeting's title or notes. The pattern is MacTower's:
/// a project key of letters, digits and underscores, a dash, a number
/// without a leading zero, and nothing alphanumeric glued to the front.
public enum TaskMeetingLink {
    public static let keyPattern = #"(?<![A-Z0-9])[A-Z][A-Z0-9_]{1,19}-[1-9][0-9]{0,9}(?![0-9])"#

    /// Unique keys in order of appearance.
    public static func keys(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: keyPattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen: Set<String> = []
        var result: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let matched = Range(match.range, in: text) else { continue }
            let key = String(text[matched])
            if seen.insert(key).inserted { result.append(key) }
        }
        return result
    }
}

/// Meeting time that needs a task chosen by hand: no key, or more than one.
public struct TaskMeetingTimeRequest: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let meetingID: UUID
    public let title: String
    public let startedAt: Date
    public let seconds: Int
    public init(meetingID: UUID, title: String, startedAt: Date, seconds: Int) {
        id = meetingID
        self.meetingID = meetingID
        self.title = title
        self.startedAt = startedAt
        self.seconds = seconds
    }
}

extension TasksWorkspaceModel {
    /// The mirrored task whose key is the one key in the text; nil for none or several.
    public func task(matchingKeysIn title: String, notes: String) -> UUID? {
        let keys = TaskMeetingLink.keys(in: title + "\n" + notes)
        guard keys.count == 1 else { return nil }
        return resolveReference(keys[0])
    }

    /// A draft for the meeting when its task is clear; otherwise a request for the chooser.
    public func logMeeting(title: String, notes: String, meetingID: UUID, seconds: Int, startedAt: Date? = nil) async {
        let start = startedAt ?? Date().addingTimeInterval(-TimeInterval(seconds))
        if let taskID = task(matchingKeysIn: title, notes: notes) {
            await logMeeting(taskID: taskID, meetingID: meetingID, title: title, seconds: seconds, startedAt: start)
        } else {
            pendingMeetingTime = TaskMeetingTimeRequest(meetingID: meetingID, title: title, startedAt: start, seconds: seconds)
        }
    }

    public func logMeeting(taskID: UUID, meetingID: UUID, title: String, seconds: Int, startedAt: Date) async {
        pendingMeetingTime = nil
        let suggest = (try? await service.time.suggestsWorklog(taskID: taskID)) ?? false
        draft = service.time.draft(manual: taskID, startedAt: startedAt, seconds: seconds, note: title, meetingID: meetingID, sendToJira: suggest, source: .meeting)
    }

    /// A short code or Jira key typed or found in text.
    public func resolveReference(_ reference: String) -> UUID? {
        let upper = reference.trimmingCharacters(in: .whitespaces).uppercased()
        if let task = tasks.first(where: { $0.code == upper && $0.deletedAt == nil }) { return task.id }
        return observations.first { $0.value.issue.key.uppercased() == upper }?.key
    }
}
