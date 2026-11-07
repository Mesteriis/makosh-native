import Foundation
import MakoshCore
import MakoshJira

public enum TasksSpace: Equatable, Sendable {
    case mine
    case jira(UUID)
}

public enum TasksFilter: Equatable, Hashable, Sendable {
    case all, today, tomorrow, week, month, overdue
    case status(TaskStatus)
    case list(String)
    case tag(String)

    public var key: String {
        switch self {
        case .all: "all"
        case .today: "today"
        case .tomorrow: "tomorrow"
        case .week: "week"
        case .month: "month"
        case .overdue: "overdue"
        case .status(let value): "status:" + value.rawValue
        case .list(let value): "list:" + value
        case .tag(let value): "tag:" + value
        }
    }
    static func from(key: String) -> TasksFilter {
        switch key {
        case "today": return .today
        case "tomorrow": return .tomorrow
        case "week": return .week
        case "month": return .month
        case "overdue": return .overdue
        default:
            if key.hasPrefix("status:"), let status = TaskStatus(rawValue: String(key.dropFirst(7))) { return .status(status) }
            if key.hasPrefix("list:") { return .list(String(key.dropFirst(5))) }
            if key.hasPrefix("tag:") { return .tag(String(key.dropFirst(4))) }
            return .all
        }
    }
}

/// One column of the Jira board: a workflow status, or a category when the project has too many statuses.
public struct JiraBoardColumn: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let category: JiraStatusCategory
    public var tasks: [Task]
}

/// What the card asks Jira to do; every action becomes one journal attempt.
public enum JiraAction: Sendable {
    case transition(JiraTransition, fields: [String: JiraFieldValue])
    case comment(String)
    case fields(JiraIssuePatch)
    case assign(accountID: String?)
}

/// The section's state and commands. Reads come from `TasksService`
/// snapshots; every write goes through the store's revisions, so a stale
/// row is refused rather than overwritten.
@MainActor public final class TasksWorkspaceModel: ObservableObject {
    public static let boardStatusLimit = 8

    @Published public var space: TasksSpace = .mine { didSet { applyFilters() } }
    @Published public var filter: TasksFilter = .all {
        didSet {
            applyFilters()
            savePreferences()
        }
    }
    @Published public var sort: TasksSort = .priority {
        didSet {
            applyFilters()
            savePreferences()
        }
    }
    @Published public var showCompleted = true {
        didSet {
            applyFilters()
            savePreferences()
        }
    }
    @Published public var search = "" { didSet { applyFilters() } }
    /// In a connection's space: also show issues that left the selection («Ушедшие»).
    @Published public var showLeft = false { didSet { applyFilters() } }
    @Published public var selection = TaskSelection()
    @Published public var toasts: [TasksToast] = []
    @Published public internal(set) var lastAction: String?
    /// The single selected task, for the card; setting it makes a one-row selection.
    public var selected: UUID? {
        get { selection.selected.count == 1 ? selection.selected.first : nil }
        set {
            if let id = newValue, let index = visible.firstIndex(where: { $0.id == id }) {
                selection.click(index: index, id: id, shift: false, command: false, visible: visible.map(\.id))
            } else if let id = newValue {
                selection.selected = [id]
            } else {
                selection.clear()
            }
        }
    }
    @Published public private(set) var tasks: [Task] = []
    @Published public private(set) var visible: [Task] = []
    @Published public private(set) var board: [JiraBoardColumn] = []
    @Published public private(set) var observations: [UUID: TaskProviderObservation] = [:]
    @Published public private(set) var attemptsByTask: [UUID: [TaskJiraAttempt]] = [:]
    @Published public private(set) var entriesByTask: [UUID: [TaskTimeEntry]] = [:]
    @Published public private(set) var connections: [JiraConnection] = []
    @Published public private(set) var projectStatuses: [UUID: [String: [JiraStatus]]] = [:]
    @Published public private(set) var priorities: [UUID: [JiraPriority]] = [:]
    @Published public private(set) var timer: TaskTimer?
    @Published public private(set) var timerElapsed = 0
    @Published public var draft: TaskTimeDraft?
    /// Meeting time waiting for the user to pick the task.
    @Published public var pendingMeetingTime: TaskMeetingTimeRequest?
    @Published public private(set) var summary: (daySeconds: Int, weekSeconds: Int) = (0, 0)
    @Published public var error: String?
    @Published public private(set) var quickEntryPreview: TaskQuickEntry?
    @Published public private(set) var syncing = false
    @Published public private(set) var loading = false

    public let service: TasksService
    public let calendar: Calendar
    let now: @Sendable () -> Date
    var undo = TaskUndoHistory()
    private var seenOutsideChanges = 0
    private var ticking: _Concurrency.Task<Void, Never>?
    private var preferencesLoaded = false

    public init(service: TasksService, calendar: Calendar = .current, now: @escaping @Sendable () -> Date = Date.init) {
        self.service = service
        self.calendar = calendar
        self.now = now
    }

    public var undoCount: Int { undo.count }

    // MARK: Reading

    public func task(id: UUID) -> Task? { tasks.first { $0.id == id } }
    public func observation(id: UUID) -> TaskProviderObservation? { observations[id] }
    public func attempts(id: UUID) -> [TaskJiraAttempt] { attemptsByTask[id] ?? [] }
    public func entries(id: UUID) -> [TaskTimeEntry] { entriesByTask[id] ?? [] }
    public func connection(for task: Task) -> JiraConnection? {
        guard let source = task.source, let id = UUID(uuidString: source.identity.accountID) else { return nil }
        return connections.first { $0.id == id }
    }
    public func isBlocked(_ task: Task) -> Bool { TaskDomain.isBlocked(task) { self.task(id: $0) } }
    public func blockers(_ task: Task) -> [Task] { TaskDomain.blockers(task) { self.task(id: $0) } }
    public func isOverdue(_ task: Task) -> Bool { TaskDomain.isOverdue(task, today: now(), calendar: calendar) }
    public var lists: [String] { Array(Set(tasks.filter { $0.deletedAt == nil }.compactMap(\.list))).sorted() }
    public var tags: [String] { Array(Set(tasks.filter { $0.deletedAt == nil }.flatMap(\.tags))).sorted() }

    public func count(_ filter: TasksFilter) -> Int {
        mineTasks.filter { matches($0, filter: filter) && (showCompleted || !isClosed($0)) }.count
    }

    public func refresh() async {
        loading = true
        defer { loading = false }
        let snapshot = await service.snapshot()
        tasks = snapshot.tasks
        observations = snapshot.observations
        attemptsByTask = snapshot.attempts
        entriesByTask = snapshot.entries
        connections = snapshot.connections
        projectStatuses = snapshot.projectStatuses
        priorities = snapshot.priorities
        timer = snapshot.timer
        if let failure = snapshot.journalFailure { error = failure }
        if !preferencesLoaded {
            preferencesLoaded = true
            applyPreferences(snapshot.preferences)
        }
        let outside = await service.outsideChanges
        if outside != seenOutsideChanges {
            let first = seenOutsideChanges == 0
            seenOutsideChanges = outside
            undo.clear()
            if !first || !tasks.isEmpty { toast("Обновлено извне") }
        }
        summary = (try? await service.time.summary(day: now(), calendar: calendar)) ?? (0, 0)
        tick()
        applyFilters()
    }

    public func syncNow() async {
        syncing = true
        defer { syncing = false }
        let results = await service.syncAll(full: true)
        if let failure = results.values.compactMap(\.failure).first { error = failure }
        await refresh()
    }

    public func refreshIssue(id: UUID) async {
        do {
            _ = try await service.refreshIssue(taskID: id)
            await refresh()
        } catch { self.error = Self.describe(error) }
    }

    // MARK: Quick entry

    public func previewQuickEntry(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            quickEntryPreview = nil
            return
        }
        quickEntryPreview = TaskQuickEntry.parse(text, today: now(), calendar: calendar, resolveDependency: resolveDependency)
    }

    public func create(quickEntry text: String) async {
        let entry = TaskQuickEntry.parse(text, today: now(), calendar: calendar, resolveDependency: resolveDependency)
        guard !entry.title.isEmpty else { return }
        let task = Task(
            title: entry.title, status: .inbox, priority: entry.priority ?? 4, list: entry.list, tags: entry.tags, due: entry.due,
            url: entry.url,
            dependsOn: entry.dependencies, createdAt: now())
        do {
            try await service.store.insert(task, actor: .user)
            quickEntryPreview = nil
            await refresh()
        } catch { self.error = Self.describe(error) }
    }

    private func resolveDependency(_ reference: String) -> UUID? {
        let upper = reference.uppercased()
        if let task = tasks.first(where: { $0.code == upper && $0.deletedAt == nil }) { return task.id }
        return observations.first { $0.value.issue.key.uppercased() == upper }?.key
    }

    // MARK: Local edits

    public func cycleStatus(id: UUID) async {
        guard let task = task(id: id) else { return }
        await set(status: TaskDomain.nextCycleStatus(task.status, blocked: isBlocked(task)), id: id)
    }

    public func set(status: TaskStatus, id: UUID) async {
        guard let task = task(id: id) else { return }
        do {
            let changed = try TaskDomain.applying(status: status, to: task, now: now()) { self.task(id: $0) }
            try await write(changed, from: task)
        } catch let error as TaskDomainError {
            if case .blocked(let ids) = error {
                self.error = TasksFailure.blocked(ids.compactMap { self.task(id: $0)?.title }).errorDescription
            } else {
                self.error = Self.describe(error)
            }
        } catch { self.error = Self.describe(error) }
    }

    public func set(priority: Int, id: UUID) async {
        guard let task = task(id: id), (1...4).contains(priority) else { return }
        var value = task
        value.priority = priority
        await edit(value, from: task)
    }

    public func postpone(id: UUID) async {
        guard let task = task(id: id) else { return }
        await edit(TaskDomain.postponed(task, today: now(), calendar: calendar), from: task)
    }

    public func delete(id: UUID) async {
        guard let task = task(id: id) else { return }
        var value = task
        value.deletedAt = now()
        await edit(value, from: task)
        selection.selected.remove(id)
    }

    /// Any field edit from the card; the revision in `task` must be current.
    public func update(_ task: Task) async {
        guard let current = self.task(id: task.id) else { return }
        await edit(task, from: current)
    }

    public func addDependency(id: UUID, on dependencyID: UUID) async {
        guard let task = task(id: id), !task.dependsOn.contains(dependencyID) else { return }
        guard !TaskDomain.wouldCreateCycle(adding: dependencyID, to: id, resolve: { self.task(id: $0) }) else {
            error = TasksFailure.cycle.errorDescription
            return
        }
        var value = task
        value.dependsOn.append(dependencyID)
        await edit(value, from: task)
    }

    public func removeDependency(id: UUID, on dependencyID: UUID) async {
        guard let task = task(id: id) else { return }
        var value = task
        value.dependsOn.removeAll { $0 == dependencyID }
        await edit(value, from: task)
    }

    public func keep(id: UUID) async { await setMembership(id: id, .kept) }
    public func unkeep(id: UUID) async { await setMembership(id: id, .none) }

    private func setMembership(id: UUID, _ membership: TaskMembership) async {
        do {
            try await service.store.setMembership(taskID: id, membership)
            await refresh()
        } catch { self.error = Self.describe(error) }
    }

    private func edit(_ value: Task, from original: Task) async {
        do { try await write(value, from: original) } catch { self.error = Self.describe(error) }
    }

    private func write(_ value: Task, from original: Task) async throws {
        let written = try await service.store.apply(value, expectedRevision: original.revision, actor: .user)
        undo.record(TaskUndoStep(change: TaskChange(before: original, after: written.task), at: now()))
        error = nil
        await refresh()
        let activated = written.effects.activated.compactMap { task(id: $0)?.title }
        if !activated.isEmpty { toast("Активированы: " + activated.joined(separator: ", ")) }
    }

    /// Reverts the newest step whole; a task that changed since makes the whole step unavailable.
    public func undo() async {
        guard let step = undo.pop(now: now()) else { return }
        do {
            let changes = step.changes
            try await service.store.performInTransaction { store in
                for change in changes {
                    guard let current = try store.task(id: change.after.id), current.revision == change.after.revision else {
                        throw TaskStoreError.staleRevision
                    }
                }
                for change in changes {
                    var restored = change.before
                    restored.revision = change.after.revision
                    try store.apply(restored, expectedRevision: change.after.revision, actor: .user)
                }
            }
            error = nil
            await refresh()
            toast("Отменено")
        } catch TaskStoreError.staleRevision {
            error = "Задача менялась — отменить нельзя."
        } catch { self.error = Self.describe(error) }
    }

    // MARK: Jira

    public func jira(_ action: JiraAction, id: UUID) async {
        guard let task = task(id: id), let source = task.source, let connectionID = UUID(uuidString: source.identity.accountID) else {
            return
        }
        let payload: TaskJiraAttempt.Payload
        let kind: TaskJiraAttempt.Kind
        switch action {
        case .transition(let transition, let fields):
            do { try JiraFieldSupport.validate(transition, fields: fields) } catch let failure as JiraAdapterError {
                if case .unsupportedFields(let keys) = failure {
                    error = TasksFailure.unsupportedFields(keys).errorDescription
                } else {
                    error = "Заполните обязательные поля перехода."
                }
                return
            } catch {
                self.error = Self.describe(error)
                return
            }
            payload = .transition(id: transition.id, toStatusID: transition.to.id, fields: fields)
            kind = .transition
        case .comment(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            payload = .comment(text: text, adf: JiraADF.document(fromText: text))
            kind = .comment
        case .fields(let patch):
            if let issue = observations[id]?.issue {
                do { try patch.validate(against: issue) } catch {
                    self.error = TasksFailure.descriptionNotEditable.errorDescription
                    return
                }
            }
            payload = .fields(patch)
            kind = .fields
        case .assign(let accountID):
            payload = .assignee(accountID: accountID)
            kind = .assignee
        }
        let attempt = await service.journal.submit(
            TaskJiraAttempt(
                taskID: id, connectionID: connectionID, issueID: source.identity.externalID, kind: kind, payload: payload, createdAt: now())
        )
        if attempt.reason == "уже выполняется" { error = TasksFailure.attemptInFlight.errorDescription }
        if attempt.state == .confirmed {
            error = nil
            await refreshIssue(id: id)
        } else {
            if attempt.state == .rejected { error = "Jira отклонила действие: " + (attempt.reason ?? "") }
            await refresh()
        }
    }

    /// Required fields the card renders for a transition (supported types only).
    public func transitionRequirements(_ transition: JiraTransition) -> [JiraField] {
        transition.fields.filter { $0.required && JiraFieldSupport.isSupported($0) }
    }

    /// Required fields Makosh cannot fill; the card shows «только в Jira» for them.
    public func blockedFields(_ transition: JiraTransition) -> [JiraField] { JiraFieldSupport.unsupportedRequired(transition) }

    public func canEditDescription(id: UUID) -> Bool {
        guard let adf = observations[id]?.issue.descriptionADF else { return true }
        return JiraADF.isSimple(adf)
    }

    public func openAttempts(id: UUID) -> [TaskJiraAttempt] { attempts(id: id).filter(\.isOpen) }

    public func assignableUsers(id: UUID, query: String) async -> [JiraUser] {
        guard let task = task(id: id), let source = task.source, let connectionID = UUID(uuidString: source.identity.accountID),
            let project = observations[id]?.issue.projectKey, let adapter = await service.adapter(for: connectionID)
        else { return [] }
        return (try? await adapter.assignableUsers(projectKey: project, query: query)) ?? []
    }

    public func resolveAttempt(id attemptID: UUID) async {
        let attempt = await service.journal.resolve(attemptID)
        if attempt.kind == .worklog { try? await service.time.applyAttempt(attempt) }
        if attempt.state == .confirmed { await refreshIssue(id: attempt.taskID) } else { await refresh() }
    }

    public func dismissAttempt(id attemptID: UUID) async {
        if let attempt = await service.journal.dismiss(attemptID), attempt.kind == .worklog {
            try? await service.time.applyAttempt(attempt)
        }
        await refresh()
    }

    // MARK: Time

    public func startTimer(id: UUID) async {
        do {
            timer = try await service.time.start(taskID: id, note: "")
            error = nil
            startTicking()
        } catch let failure as TasksFailure {
            error = failure.errorDescription
        } catch { self.error = Self.describe(error) }
    }

    public func stopTimer() async {
        do {
            draft = try await service.time.stop()
            timer = nil
            stopTicking()
            timerElapsed = 0
        } catch { self.error = Self.describe(error) }
    }

    public func logManual(id: UUID, startedAt: Date, seconds: Int, note: String, meetingID: UUID? = nil) async {
        let suggest = (try? await service.time.suggestsWorklog(taskID: id)) ?? false
        draft = service.time.draft(
            manual: id, startedAt: startedAt, seconds: seconds, note: note, meetingID: meetingID, sendToJira: suggest)
    }

    public func confirmDraft() async {
        guard let draft else { return }
        do {
            _ = try await service.time.confirm(draft)
            self.draft = nil
            error = nil
            await refresh()
        } catch TaskStoreError.duplicate {
            self.draft = nil
            await refresh()
        } catch { self.error = Self.describe(error) }
    }

    /// Cancelling a timer's draft keeps the time: the timer resumes from its original start.
    public func discardDraft() async {
        guard let draft else { return }
        self.draft = nil
        if draft.source == .timer {
            try? await service.time.restore(draft)
            timer = try? await service.time.timer()
            startTicking()
            tick()
        }
    }

    public func updateEntry(_ entry: TaskTimeEntry) async {
        do {
            _ = try await service.time.update(entry)
            await refresh()
        } catch { self.error = Self.describe(error) }
    }

    public func deleteEntry(id: UUID) async {
        do {
            try await service.time.delete(entryID: id)
            await refresh()
        } catch { self.error = Self.describe(error) }
    }

    /// Recomputes the running timer's elapsed seconds; the ticking task calls it every second.
    public func tick() {
        guard let timer else {
            timerElapsed = 0
            return
        }
        timerElapsed = max(0, Int(now().timeIntervalSince(timer.startedAt)))
    }

    public func startTicking() {
        guard ticking == nil else { return }
        ticking = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                do { try await _Concurrency.Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.tick()
            }
        }
    }

    public func stopTicking() {
        ticking?.cancel()
        ticking = nil
    }

    // MARK: Filtering

    private var mineTasks: [Task] {
        tasks.filter { $0.deletedAt == nil && ($0.source == nil || $0.source?.membership != TaskMembership.none) }
    }

    private func isClosed(_ task: Task) -> Bool { task.status == .done || task.status == .cancelled }

    private func matches(_ task: Task, filter: TasksFilter) -> Bool {
        let today = calendar.startOfDay(for: now())
        func within(days: Int) -> Bool {
            guard let due = task.due, let end = calendar.date(byAdding: .day, value: days, to: today) else { return false }
            return calendar.startOfDay(for: due) < end && !isClosed(task)
        }
        switch filter {
        case .all: return true
        case .today: return task.due.map { calendar.isDate($0, inSameDayAs: today) } ?? false
        case .tomorrow:
            return task.due.map { calendar.isDate($0, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: today) ?? today) } ?? false
        case .week: return within(days: 7)
        case .month: return within(days: 31)
        case .overdue: return isOverdue(task)
        case .status(let status): return task.status == status
        case .list(let list): return task.list == list
        case .tag(let tag): return task.tags.contains(tag)
        }
    }

    private func applyFilters() {
        let needle = Self.fold(search)
        func searched(_ task: Task) -> Bool {
            guard !needle.isEmpty else { return true }
            if task.code.lowercased() == needle { return true }
            let key = observations[task.id]?.issue.key.lowercased() ?? ""
            return Self.fold(task.title).contains(needle) || key.contains(needle) || task.tags.contains { Self.fold($0).contains(needle) }
        }
        switch space {
        case .mine:
            var result = mineTasks.filter { matches($0, filter: filter) && (showCompleted || !isClosed($0)) && searched($0) }
            result.sort { lhs, rhs in
                let primary: Bool?
                switch sort {
                case .priority: primary = lhs.priority == rhs.priority ? nil : lhs.priority < rhs.priority
                case .status:
                    let order = TaskDomain.fullCycle
                    let l = order.firstIndex(of: lhs.status) ?? 0, r = order.firstIndex(of: rhs.status) ?? 0
                    primary = l == r ? nil : l < r
                case .due:
                    switch (lhs.due, rhs.due) {
                    case (nil, nil): primary = nil
                    case (nil, _): primary = false
                    case (_, nil): primary = true
                    case (let l?, let r?): primary = l == r ? nil : l < r
                    }
                case .created: primary = lhs.createdAt == rhs.createdAt ? nil : lhs.createdAt > rhs.createdAt
                }
                return primary ?? (lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending)
            }
            visible = result
            board = []
        case .jira(let connectionID):
            // Issues that left the selection stay reachable: by search, or with «Ушедшие» on.
            let includeLeft = showLeft || !needle.isEmpty
            let rows = tasks.filter { task in
                guard task.deletedAt == nil, let source = task.source, source.identity.accountID == connectionID.uuidString else {
                    return false
                }
                return (source.membership != TaskMembership.none || includeLeft) && searched(task)
            }
            visible = rows
            board = Self.columns(for: rows, statuses: projectStatuses[connectionID] ?? [:], observations: observations)
        }
        selection.clamp(to: visible.map(\.id))
    }

    static func columns(
        for tasks: [Task], statuses: [String: [JiraStatus]], observations: [UUID: TaskProviderObservation]
    ) -> [JiraBoardColumn] {
        var known: [JiraStatus] = []
        var seen: Set<String> = []
        for project in statuses.keys.sorted() {
            for status in statuses[project] ?? [] where seen.insert(status.name).inserted { known.append(status) }
        }
        for task in tasks {
            if let status = observations[task.id]?.issue.status, seen.insert(status.name).inserted { known.append(status) }
        }
        let order: [JiraStatusCategory] = [.new, .indeterminate, .done, .undefined]
        known.sort { lhs, rhs in
            let l = order.firstIndex(of: lhs.category) ?? 3, r = order.firstIndex(of: rhs.category) ?? 3
            return l == r ? false : l < r
        }
        if known.count > boardStatusLimit {
            let titles: [(JiraStatusCategory, String)] = [(.new, "К выполнению"), (.indeterminate, "В работе"), (.done, "Готово")]
            return titles.map { category, title in
                JiraBoardColumn(
                    id: "category:" + category.rawValue, title: title, category: category,
                    tasks: tasks.filter { (observations[$0.id]?.issue.status.category ?? .undefined) == category })
            }
        }
        return known.map { status in
            JiraBoardColumn(
                id: "status:" + status.name, title: status.name, category: status.category,
                tasks: tasks.filter { observations[$0.id]?.issue.status.name == status.name })
        }
    }

    // MARK: Preferences

    private var preferences = TaskPreferences()

    // The single filter of the first part is bridged onto the stored v2 shape
    // until the combinable filters replace it.
    private func applyPreferences(_ preferences: TaskPreferences) {
        let loaded = preferencesLoaded
        preferencesLoaded = false
        self.preferences = preferences
        sort = preferences.sort ?? .priority
        let snapshot = preferences.filters
        let key: String
        if let agenda = snapshot.agenda {
            key = agenda
        } else if let status = snapshot.status {
            key = "status:" + status
        } else if let list = snapshot.list {
            key = "list:" + list
        } else if let tag = snapshot.tag {
            key = "tag:" + tag
        } else {
            key = "all"
        }
        filter = TasksFilter.from(key: key)
        showCompleted = !snapshot.actualOnly
        preferencesLoaded = loaded
    }

    private func savePreferences() {
        guard preferencesLoaded else { return }
        var value = preferences
        value.sort = sort
        var snapshot = TasksFiltersSnapshot()
        switch filter {
        case .all: break
        case .today, .tomorrow, .week, .month, .overdue: snapshot.agenda = filter.key
        case .status(let status): snapshot.status = status.rawValue
        case .list(let list): snapshot.list = list
        case .tag(let tag): snapshot.tag = tag
        }
        snapshot.actualOnly = !showCompleted
        value.filters = snapshot
        value.showCompleted = showCompleted
        preferences = value
        let service = service
        _Concurrency.Task { try? await service.store.savePreferences(value) }
    }

    public static func fold(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    public static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as TasksFailure: return failure.errorDescription ?? "Ошибка раздела «Задачи»."
        case TaskStoreError.staleRevision: return TasksFailure.staleRevision.errorDescription ?? ""
        case TaskStoreError.duplicate: return "Такая запись уже есть."
        case let failure as TaskStoreError: return "Хранилище задач: \(failure)."
        case let failure as JiraAdapterError: return "Jira: " + JiraDiagnostics.code(failure)
        case let failure as LocalizedError: return failure.errorDescription ?? "Не удалось выполнить действие."
        default: return "Не удалось выполнить действие."
        }
    }
}
