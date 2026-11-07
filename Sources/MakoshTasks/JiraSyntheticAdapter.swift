import Foundation
import MakoshJira

/// A Jira that lives in memory for the synthetic preview: six issues in two
/// projects, a workflow whose Done transition asks for a resolution, one
/// issue with a table in its description, one that reaches the user only by
/// mention. Writes change its state; `failNext` scripts one failure.
public actor JiraSyntheticAdapter: JiraAdapter {
    public static let me = JiraUser(accountID: "me-1", displayName: "Я")
    public static let bob = JiraUser(accountID: "bob-1", displayName: "Боб Петров")
    public static let toDo = JiraStatus(id: "1", name: "To Do", category: .new)
    public static let inProgress = JiraStatus(id: "2", name: "In Progress", category: .indeterminate)
    public static let review = JiraStatus(id: "4", name: "In Review", category: .indeterminate)
    public static let done = JiraStatus(id: "3", name: "Done", category: .done)

    private var issues: [String: JiraIssue]
    private var comments: [String: [JiraComment]] = [:]
    private var worklogs: [String: [JiraWorklog]] = [:]
    private var pendingFailure: JiraAdapterError?
    private var counter = 500
    private let clock: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        clock = now
        let base = now()
        let table = Data(
            #"{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Сверка по счетам:"}]},{"type":"table","content":[{"type":"tableRow","content":[{"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"Счёт"}]}]},{"type":"tableHeader","content":[{"type":"paragraph","content":[{"type":"text","text":"Сумма"}]}]}]},{"type":"tableRow","content":[{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"A-1"}]}]},{"type":"tableCell","content":[{"type":"paragraph","content":[{"type":"text","text":"12 000"}]}]}]}]}]}"#
                .utf8)
        func issue(_ id: String, _ key: String, _ project: String, _ summary: String, _ status: JiraStatus, assignee: JiraUser? = Self.me, description: String? = nil, adf: Data? = nil, priority: JiraPriority? = nil, due: Date? = nil) -> JiraIssue {
            let adf = adf ?? description.map { JiraADF.document(fromText: $0) }
            return JiraIssue(
                id: id, key: key, projectKey: project, summary: summary, descriptionADF: adf, descriptionText: adf.map(JiraADF.text(from:)) ?? "",
                status: status, issueType: "Task", priority: priority, assignee: assignee, reporter: Self.bob, labels: project == "OPS" ? ["ops"] : [], due: due,
                updated: base, browseURL: URL(string: "https://jira.synthetic.test/browse/\(key)")!)
        }
        issues = [
            "1001": issue("1001", "QA-1", "QA", "Проверить форму входа", Self.toDo, description: "Шаги:\n1. Открыть форму\n2. Ввести данные", priority: JiraPriority(id: "2", name: "High"), due: base.addingTimeInterval(86_400 * 3)),
            "1002": issue("1002", "QA-2", "QA", "Сверить счета за октябрь", Self.inProgress, adf: table, priority: JiraPriority(id: "3", name: "Medium")),
            "1003": issue("1003", "QA-3", "QA", "Обновить тест-план", Self.review, description: "Черновик готов, нужна вычитка."),
            "1004": issue("1004", "OPS-7", "OPS", "Перенести бэкапы на новый диск", Self.toDo, assignee: Self.bob, description: "@Я посмотри, пожалуйста, объём."),
            "1005": issue("1005", "OPS-8", "OPS", "Ротация сертификатов", Self.inProgress, description: "Истекают 20-го."),
            "1006": issue("1006", "OPS-9", "OPS", "Старая задача", Self.done, description: "Закрыта в прошлом месяце."),
        ]
        comments["1004"] = [
            JiraComment(
                id: "c1", author: Self.bob, created: base.addingTimeInterval(-3600), updated: base.addingTimeInterval(-3600),
                bodyADF: JiraADF.document(fromText: "@Я посмотри, пожалуйста, объём.", mentions: ["Я": "Self.me-1"]), bodyText: "@Я посмотри, пожалуйста, объём.")
        ]
        worklogs["1002"] = [JiraWorklog(id: "w1", author: Self.me, started: base.addingTimeInterval(-7200), seconds: 1800, commentText: "сверка")]
    }

    /// The next write throws this error once; the write still lands, like a lost response would.
    public func failNext(_ error: JiraAdapterError) { pendingFailure = error }

    private func takeFailure() throws {
        guard let failure = pendingFailure else { return }
        pendingFailure = nil
        throw failure
    }
    private func newID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)\(counter)"
    }
    private func transitions(for status: JiraStatus) -> [JiraTransition] {
        let finish = JiraTransition(
            id: "31", name: "Done", to: Self.done,
            fields: [
                JiraField(
                    key: "resolution", name: "Resolution", required: true, schemaType: "resolution",
                    allowedValues: [JiraFieldOption(id: "10000", name: "Done"), JiraFieldOption(id: "10001", name: "Won't Do")])
            ])
        switch status.id {
        case Self.toDo.id: return [JiraTransition(id: "11", name: "Start", to: Self.inProgress), finish]
        case Self.inProgress.id: return [JiraTransition(id: "21", name: "Review", to: Self.review), JiraTransition(id: "12", name: "Back", to: Self.toDo), finish]
        case Self.review.id: return [JiraTransition(id: "22", name: "Rework", to: Self.inProgress), finish]
        default: return [JiraTransition(id: "41", name: "Reopen", to: Self.toDo)]
        }
    }

    public func currentUser() async throws -> JiraUser { Self.me }

    public func searchIssues(jql: String, nextToken: String?, limit: Int) async throws -> JiraPage<JiraIssue> {
        let mine = issues.values.filter { issue in
            issue.assignee?.accountID == Self.me.accountID || (comments[issue.id] ?? []).contains { $0.bodyText.contains("@Я") }
        }
        return JiraPage(items: mine.sorted { $0.key < $1.key }, nextToken: nil)
    }

    public func issue(id: String) async throws -> JiraIssue {
        guard let issue = issues[id] else { throw JiraAdapterError.notFound }
        return issue
    }

    public func transitions(issueID: String) async throws -> [JiraTransition] {
        guard let issue = issues[issueID] else { throw JiraAdapterError.notFound }
        return transitions(for: issue.status)
    }

    public func comments(issueID: String, nextToken: String?) async throws -> JiraPage<JiraComment> {
        JiraPage(items: comments[issueID] ?? [], nextToken: nil)
    }

    public func worklogs(issueID: String) async throws -> [JiraWorklog] { worklogs[issueID] ?? [] }

    public func projectStatuses(projectKey: String) async throws -> [JiraStatus] {
        projectKey == "QA" ? [Self.toDo, Self.inProgress, Self.review, Self.done] : [Self.toDo, Self.inProgress, Self.done]
    }

    public func priorities() async throws -> [JiraPriority] {
        [JiraPriority(id: "1", name: "Highest"), JiraPriority(id: "2", name: "High"), JiraPriority(id: "3", name: "Medium"), JiraPriority(id: "4", name: "Low")]
    }

    public func assignableUsers(projectKey: String, query: String) async throws -> [JiraUser] {
        [Self.bob, Self.me, JiraUser(accountID: "ann-1", displayName: "Анна Сидорова")].filter {
            query.isEmpty || $0.displayName.lowercased().contains(query.lowercased())
        }
    }

    public func addWorklog(issueID: String, started: Date, seconds: Int, comment: String?) async throws -> String {
        guard issues[issueID] != nil else { throw JiraAdapterError.notFound }
        guard seconds >= 60 else { throw JiraAdapterError.invalidRequest }
        let id = newID("w")
        worklogs[issueID, default: []].append(JiraWorklog(id: id, author: Self.me, started: started, seconds: seconds, commentText: comment ?? ""))
        try takeFailure()
        return id
    }

    public func addComment(issueID: String, body: Data) async throws -> String {
        guard issues[issueID] != nil else { throw JiraAdapterError.notFound }
        let id = newID("c")
        let now = clock()
        comments[issueID, default: []].append(JiraComment(id: id, author: Self.me, created: now, updated: now, bodyADF: body, bodyText: JiraADF.text(from: body)))
        try takeFailure()
        return id
    }

    public func transition(issueID: String, transitionID: String, fields: [String: JiraFieldValue]) async throws {
        guard var issue = issues[issueID] else { throw JiraAdapterError.notFound }
        guard let transition = transitions(for: issue.status).first(where: { $0.id == transitionID }) else { throw JiraAdapterError.invalidRequest }
        try JiraFieldSupport.validate(transition, fields: fields)
        issue.status = transition.to
        issue.updated = clock()
        issues[issueID] = issue
        try takeFailure()
    }

    public func updateFields(issueID: String, patch: JiraIssuePatch) async throws {
        guard var issue = issues[issueID] else { throw JiraAdapterError.notFound }
        try patch.validate(against: issue)
        if let summary = patch.summary { issue.summary = summary }
        if let labels = patch.labels { issue.labels = labels }
        if let due = patch.due { issue.due = due }
        if let priorityID = patch.priorityID { issue.priority = try await priorities().first { $0.id == priorityID } }
        if let description = patch.descriptionADF {
            issue.descriptionADF = description
            issue.descriptionText = JiraADF.text(from: description)
        }
        issue.updated = clock()
        issues[issueID] = issue
        try takeFailure()
    }

    public func assign(issueID: String, accountID: String?) async throws {
        guard var issue = issues[issueID] else { throw JiraAdapterError.notFound }
        if let accountID {
            let users = try await assignableUsers(projectKey: issue.projectKey, query: "")
            issue.assignee = users.first { $0.accountID == accountID } ?? JiraUser(accountID: accountID, displayName: accountID)
        } else {
            issue.assignee = nil
        }
        issue.updated = clock()
        issues[issueID] = issue
        try takeFailure()
    }
}
