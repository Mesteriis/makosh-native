import Foundation
import MakoshCore
import MakoshJira

public enum TasksSpace: Equatable, Sendable {
    case mine
    case jira(UUID)
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
    @Published public var filters = TasksFilters() {
        didSet {
            applyFilters()
            savePreferences()
        }
    }
    @Published public var sortState: TasksSortState? {
        didSet {
            applyFilters()
            savePreferences()
        }
    }
    @Published public var condense = false { didSet { savePreferences() } }
    @Published public var showSidebar = true { didSet { savePreferences() } }
    @Published public var showRightPanel = true { didSet { savePreferences() } }
    @Published public var showCalendar = true { didSet { savePreferences() } }
    @Published public var showPlanner = false { didSet { savePreferences() } }
    @Published public var plannerWidthPercent = 40 { didSet { savePreferences() } }
    @Published public var collapsedSections: Set<String> = [] { didSet { savePreferences() } }
    /// How many leading rows of `visible` are overdue (they float under «Просрочено»).
    @Published public private(set) var overdueCount = 0
    @Published public private(set) var flowGroups: [TasksFlowGroup] = []
    /// The planner's day; `.distantPast` until the planner loads (then today).
    @Published public var plannerDay: Date = .distantPast {
        didSet { if oldValue != .distantPast, plannerDay != oldValue { _Concurrency.Task { await loadPlanner() } } }
    }
    @Published public internal(set) var plan: TaskDayPlan?
    @Published public internal(set) var slots: [TaskPlanSlot] = []
    @Published public internal(set) var plannedTaskIDs: Set<UUID> = []
    @Published public internal(set) var todaySlots: [TaskPlanSlot] = []
    /// Where «Создать задачу здесь» puts the next created task.
    public internal(set) var pendingSlotStart: Int?
    var trackedToday: Date?
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
    @Published public internal(set) var timer: TaskTimer?
    @Published public private(set) var timerElapsed = 0
    @Published public var draft: TaskTimeDraft?
    /// Drafts waiting behind the one on screen; focus sessions ending at once queue here.
    var draftQueue: [TaskTimeDraft] = []
    @Published public internal(set) var focusState = TaskFocusState()
    /// Meeting time waiting for the user to pick the task.
    @Published public var pendingMeetingTime: TaskMeetingTimeRequest?
    @Published public private(set) var summary: (daySeconds: Int, weekSeconds: Int) = (0, 0)
    @Published public var error: String?
    @Published public private(set) var quickEntryPreview: TaskQuickEntry?
    @Published public var quickEntry = TaskQuickEntryChips() { didSet { previewQuickEntry(quickEntry.composed()) } }
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

    public var personas: [String] { Array(Set(mineTasks.flatMap(\.personas))).sorted() }
    /// Every flow with tasks or a card.
    public var flows: [String] { Array(Set(mineTasks.compactMap(\.flowID) + flowMeta.keys)).sorted() }
    @Published public private(set) var flowMeta: [String: TaskFlow] = [:]
    public var activeFlow: String? { filters.flow }
    public var flowTasks: [Task] { activeFlow.map { flow in mineTasks.filter { $0.flowID == flow } } ?? [] }
    public func flowProgress(_ name: String) -> TaskFlowProgress { TaskFlowRules.progress(mineTasks.filter { $0.flowID == name }) }
    public var totalCount: Int { mineTasks.count }
    public var doneCount: Int { mineTasks.filter { $0.status == .done }.count }
    /// `visible.count` while anything narrows the list; nil otherwise.
    public var foundCount: Int? { filters.isFiltering || !Self.fold(search).isEmpty ? visible.count : nil }
    public var agendaCounts: [TasksAgenda: Int] {
        Dictionary(
            uniqueKeysWithValues: TasksAgenda.allCases.map { agenda in (agenda, mineTasks.filter { matches($0, agenda: agenda) }.count) })
    }
    public var statusCounts: [TaskStatus: Int] {
        Dictionary(uniqueKeysWithValues: TaskStatus.allCases.map { status in (status, mineTasks.filter { $0.status == status }.count) })
    }
    public var listCounts: [String: Int] { Self.counts(mineTasks.compactMap(\.list)) }
    public var tagCounts: [String: Int] { Self.counts(mineTasks.flatMap(\.tags)) }
    public var personaCounts: [String: Int] { Self.counts(mineTasks.flatMap(\.personas)) }
    public var flowCounts: [String: Int] { Self.counts(mineTasks.compactMap(\.flowID)) }
    private static func counts(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// Sidebar's «N задач» and the header's counter click: every filter, the day and the search.
    public func clearAll() {
        search = ""
        filters.clearFilters()
    }

    public enum EscapeResult: Equatable, Sendable { case selection, search, filters, nothing }

    /// Esc, one stage per press: selection → search → filters.
    @discardableResult public func escape() -> EscapeResult {
        if !selection.selected.isEmpty {
            selection.clear()
            return .selection
        }
        if !search.isEmpty {
            search = ""
            return .search
        }
        if filters.isFiltering {
            filters.clearFilters()
            return .filters
        }
        return .nothing
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
        flowMeta = Dictionary(snapshot.flows.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        timer = snapshot.timer
        focusState = snapshot.focus
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
        await settleClosedFocusSessions()
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
        quickEntryPreview = TaskQuickEntry.parse(
            text, today: now(), calendar: calendar, resolveDependency: resolveDependency, extractURLs: preferences.extractURLs)
    }

    /// Completions for the word being typed in the field.
    public var quickEntrySuggestions: [TaskQuickEntrySuggestion] {
        TaskQuickEntrySuggestions.make(
            for: quickEntry.text, lists: lists, tags: tags, personas: personas, flows: flows, hasList: quickEntry.hasList, today: now(),
            calendar: calendar)
    }

    /// Enter in the field: the chips and text become a task, with the active filters filled in.
    public func create() async {
        let line = quickEntry.composed()
        guard !line.isEmpty else { return }
        if await create(quickEntry: line) { quickEntry = TaskQuickEntryChips() }
    }

    @discardableResult public func create(quickEntry text: String) async -> Bool {
        let entry = TaskQuickEntry.parse(
            text, today: now(), calendar: calendar, resolveDependency: resolveDependency, extractURLs: preferences.extractURLs)
        guard !entry.title.isEmpty else { return false }
        let today = calendar.startOfDay(for: now())
        var task = Task(
            title: entry.title, status: .inbox, priority: entry.priority ?? 4, list: entry.list, tags: entry.tags, personas: entry.personas,
            due: entry.due, url: entry.url, dependsOn: entry.dependencies, recurrence: entry.recurrence, flowID: entry.flowID,
            createdAt: now())
        if task.due == nil, let agenda = filters.agenda {
            switch agenda {
            case .today, .overdue: task.due = today
            case .tomorrow: task.due = calendar.date(byAdding: .day, value: 1, to: today)
            case .week: task.due = calendar.date(byAdding: .day, value: 7, to: today)
            case .month: task.due = calendar.date(byAdding: .day, value: 30, to: today)
            }
        }
        if task.due == nil, let day = filters.day { task.due = calendar.startOfDay(for: day) }
        if filters.status == .active || (preferences.newTaskActiveToday && task.due.map { calendar.isDate($0, inSameDayAs: today) } == true)
        {
            task.status = .active
        }
        if task.list == nil, let list = filters.list { task.list = list }
        if let tag = filters.tag, !task.tags.contains(tag) { task.tags.append(tag) }
        if let persona = filters.persona, !task.personas.contains(persona) { task.personas.append(persona) }
        if task.flowID == nil, let flow = filters.flow { task.flowID = flow }
        do {
            let inserted = try await service.store.insert(task, actor: .user)
            quickEntryPreview = nil
            error = nil
            await refresh()
            var parts = ["Создана: " + inserted.title]
            if let due = inserted.due { parts.append(preferences.dateFormat.string(due, calendar: calendar)) }
            if inserted.priority != 4 { parts.append("P\(inserted.priority)") }
            if let list = inserted.list { parts.append("@" + list) }
            toast(parts.joined(separator: " · "))
            await taskCreated(inserted)
            return true
        } catch {
            self.error = Self.describe(error)
            return false
        }
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
            let changes = step.changes, slotChanges = step.slots
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
                for change in slotChanges.reversed() {
                    switch (change.before, change.after) {
                    case (nil, let added?): try store.removeSlot(id: added.id)
                    case (let removed?, nil): if try store.slot(id: removed.id) == nil { try store.insertSlot(removed) }
                    case (let before?, _): try store.updateSlot(before)
                    case (nil, nil): break
                    }
                }
            }
            error = nil
            if !slotChanges.isEmpty { await reloadAfterSlotChange() } else { await refresh() }
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
        if focusEnabled {
            await focus(id: id)
            return
        }
        do {
            timer = try await service.time.start(taskID: id, note: "")
            error = nil
            startTicking()
        } catch let failure as TasksFailure {
            error = failure.errorDescription
        } catch { self.error = Self.describe(error) }
    }

    public func stopTimer() async {
        if focusEnabled, focusState.active != nil {
            await stopFocusSession()
            return
        }
        do {
            enqueue(try await service.time.stop())
            timer = nil
            stopTicking()
            timerElapsed = 0
        } catch { self.error = Self.describe(error) }
    }

    public func logManual(id: UUID, startedAt: Date, seconds: Int, note: String, meetingID: UUID? = nil) async {
        let suggest = (try? await service.time.suggestsWorklog(taskID: id)) ?? false
        enqueue(
            service.time.draft(manual: id, startedAt: startedAt, seconds: seconds, note: note, meetingID: meetingID, sendToJira: suggest))
    }

    public func confirmDraft() async {
        guard let draft else { return }
        do {
            _ = try await service.time.confirm(draft)
            presentNextDraft()
            error = nil
            await refresh()
        } catch TaskStoreError.duplicate {
            presentNextDraft()
            await refresh()
        } catch { self.error = Self.describe(error) }
    }

    /// Cancelling a timer's draft keeps the time: the timer resumes from its original start.
    public func discardDraft() async {
        guard let draft else { return }
        presentNextDraft()
        guard draft.source == .timer, draft.reason == nil, let task = task(id: draft.taskID), task.status != .done,
            task.status != .cancelled, task.deletedAt == nil
        else { return }
        if focusEnabled {
            await focus(id: draft.taskID)
        } else {
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
        expireToasts()
        advancePlannerDay()
        tickPomodoro()
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

    private func matches(_ task: Task, agenda: TasksAgenda) -> Bool {
        let today = calendar.startOfDay(for: now())
        let overdue = isOverdue(task)
        guard let due = task.due.map({ calendar.startOfDay(for: $0) }) else { return false }
        func within(days: Int) -> Bool {
            guard let end = calendar.date(byAdding: .day, value: days, to: today) else { return false }
            return due >= today && due <= end
        }
        switch agenda {
        case .overdue: return overdue
        case .today: return overdue || calendar.isDate(due, inSameDayAs: today)
        case .tomorrow: return overdue || calendar.isDate(due, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        case .week: return overdue || within(days: 7)
        case .month: return overdue || within(days: 30)
        }
    }

    private func matches(_ task: Task) -> Bool {
        if let status = filters.status, task.status != status { return false }
        if filters.status == nil, filters.actualOnly, isClosed(task) { return false }
        if let agenda = filters.agenda, !matches(task, agenda: agenda) { return false }
        if let list = filters.list, task.list != list { return false }
        if let tag = filters.tag, !task.tags.contains(tag) { return false }
        if let persona = filters.persona, !task.personas.contains(persona) { return false }
        if let flow = filters.flow, task.flowID != flow { return false }
        if let day = filters.day {
            guard let due = task.due, calendar.isDate(due, inSameDayAs: day) else { return false }
        }
        return true
    }

    private func searched(_ task: Task, needle: String, swapped: String, reference: String?) -> Bool {
        guard !needle.isEmpty else { return true }
        if let reference, task.code.hasSuffix(reference) { return true }
        let key = observations[task.id]?.issue.key.lowercased() ?? ""
        let fields = [Self.fold(task.title), key, Self.fold(task.list ?? "")] + task.tags.map(Self.fold)
        return fields.contains { $0.contains(needle) || (swapped != needle && $0.contains(swapped)) }
    }

    private func sorted(_ tasks: [Task]) -> [Task] {
        tasks.sorted { lhs, rhs in
            var primary: Bool?
            if let sortState {
                let sign = sortState.descending ? -1 : 1
                func compare<T: Comparable>(_ l: T, _ r: T) -> Bool? { l == r ? nil : ((l < r) == (sign > 0)) }
                switch sortState.field {
                case .priority: primary = compare(lhs.priority, rhs.priority)
                case .status:
                    let order = TaskDomain.fullCycle
                    primary = compare(order.firstIndex(of: lhs.status) ?? 0, order.firstIndex(of: rhs.status) ?? 0)
                case .due:
                    switch (lhs.due, rhs.due) {
                    case (nil, nil): primary = nil
                    case (nil, _): primary = false
                    case (_, nil): primary = true
                    case (let l?, let r?): primary = compare(l, r)
                    }
                case .created: primary = compare(lhs.createdAt, rhs.createdAt)
                }
            }
            return primary ?? (lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending)
        }
    }

    private func applyFilters() {
        let needle = Self.fold(search)
        let swapped = KeyboardLayout.swapped(needle)
        let reference = needle.split(separator: " ").first.flatMap { TaskReference.normalize(String($0)) }
        switch space {
        case .mine:
            let rows = sorted(mineTasks.filter { matches($0) && searched($0, needle: needle, swapped: swapped, reference: reference) })
            let overdue = rows.filter { isOverdue($0) }
            var rest = rows.filter { !isOverdue($0) }
            if filters.groupByFlow, filters.flow == nil {
                var seen: Set<String> = []
                var grouped: [Task] = []
                for task in rest {
                    if let flow = task.flowID {
                        guard seen.insert(flow).inserted else { continue }
                        grouped += rest.filter { $0.flowID == flow }
                    } else {
                        grouped.append(task)
                    }
                }
                rest = grouped
            }
            overdueCount = overdue.count
            visible = overdue + rest
            var groups: [TasksFlowGroup] = []
            for task in rest {
                let flow = filters.groupByFlow && filters.flow == nil ? task.flowID : nil
                if let last = groups.last, last.flow == flow {
                    groups[groups.count - 1] = TasksFlowGroup(flow: flow, tasks: last.tasks + [task])
                } else {
                    groups.append(TasksFlowGroup(flow: flow, tasks: [task]))
                }
            }
            flowGroups = groups
            board = []
        case .jira(let connectionID):
            // Issues that left the selection stay reachable: by search, or with «Ушедшие» on.
            let includeLeft = showLeft || !needle.isEmpty
            let rows = tasks.filter { task in
                guard task.deletedAt == nil, let source = task.source, source.identity.accountID == connectionID.uuidString else {
                    return false
                }
                return (source.membership != TaskMembership.none || includeLeft)
                    && searched(task, needle: needle, swapped: swapped, reference: reference)
            }
            overdueCount = 0
            flowGroups = []
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

    var preferences = TaskPreferences()

    private func applyPreferences(_ preferences: TaskPreferences) {
        let loaded = preferencesLoaded
        preferencesLoaded = false
        self.preferences = preferences
        sortState = preferences.sort.map { TasksSortState(field: $0, descending: preferences.sortDescending) }
        filters = TasksFilters(snapshot: preferences.filters, calendar: calendar)
        condense = preferences.condense
        showSidebar = preferences.showSidebar
        showRightPanel = preferences.showRightPanel
        showCalendar = preferences.showCalendar
        showPlanner = preferences.showPlanner
        plannerWidthPercent = preferences.plannerWidthPercent
        collapsedSections = Set(preferences.collapsedSections)
        preferencesLoaded = loaded
    }

    private func savePreferences() {
        guard preferencesLoaded else { return }
        var value = preferences
        value.sort = sortState?.field
        value.sortDescending = sortState?.descending ?? false
        value.filters = filters.snapshot(calendar: calendar)
        value.showCompleted = !filters.actualOnly
        value.condense = condense
        value.showSidebar = showSidebar
        value.showRightPanel = showRightPanel
        value.showCalendar = showCalendar
        value.showPlanner = showPlanner
        value.plannerWidthPercent = plannerWidthPercent
        value.collapsedSections = collapsedSections.sorted()
        preferences = value
        let service = service
        _Concurrency.Task { try? await service.store.savePreferences(value) }
    }

    /// Settings and views change the stored preferences through this one door.
    public func updatePreferences(_ change: (inout TaskPreferences) -> Void) {
        var value = preferences
        change(&value)
        preferences = value
        let service = service
        _Concurrency.Task { try? await service.store.savePreferences(value) }
    }

    public var storedPreferences: TaskPreferences { preferences }

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
