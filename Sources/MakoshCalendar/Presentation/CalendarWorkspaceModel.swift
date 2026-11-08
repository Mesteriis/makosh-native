import Combine
import Foundation

package enum CalendarPendingWrite: Sendable {
    case create(CalendarDraft)
    case move(eventID: UUID, occurrenceKey: Date?, time: CalendarEventTime, scope: CalendarEditScope)
}

package struct CalendarConflictPrompt: Identifiable, Sendable {
    package let id = UUID()
    package let pending: CalendarPendingWrite
    package let conflicts: [CalendarConflict]
    /// The nearest free start of the same length, if any.
    package let suggestion: Date?
}

package enum CalendarConflictChoice: Sendable {
    case writeAnyway
    case pickTime(Date)
    case writeToOrganizer(CalendarConflict)
    case decline(CalendarConflict)
}

/// The calendar section's state on the main actor; all work goes through `CalendarService`.
@MainActor package final class CalendarWorkspaceModel: ObservableObject {
    package let service: CalendarService
    package var taskFeed: (any CalendarTaskFeed)?
    package var calendar: Foundation.Calendar
    let now: @Sendable () -> Date

    @Published package private(set) var snapshot: CalendarSnapshot?
    @Published package var period: CalendarPeriod
    @Published package private(set) var selectedCollectionID: UUID?
    @Published package var conflict: CalendarConflictPrompt?
    @Published package private(set) var groupPreview: BusyPreview?
    @Published package var error: String?
    @Published package var notice: String?
    @Published package private(set) var tasks: [CalendarTaskItem] = []
    @Published package private(set) var dueMarks: [Date: [CalendarTaskItem]] = [:]
    @Published package var agenda: CalendarTaskAgenda = .today
    @Published package private(set) var undoNeedsConfirmation = false
    @Published package private(set) var syncing = false
    /// Opens a mail draft to the address with the subject; set by the app.
    package var writeToOrganizer: (@MainActor (String, String?) -> Void)?

    private var staged: ([CalendarCollection], [CalendarGroup])?
    private var lastMove: (eventID: UUID, occurrenceKey: Date?, previous: CalendarEventTime, scope: CalendarEditScope, shared: Bool)?

    package init(service: CalendarService, calendar: Foundation.Calendar = .current, now: @escaping @Sendable () -> Date = Date.init) {
        self.service = service
        var calendar = calendar
        if calendar.firstWeekday == 1, Locale.current.language.languageCode?.identifier == "ru" { calendar.firstWeekday = 2 }
        self.calendar = calendar
        self.now = now
        period = CalendarPeriod(mode: .week, anchor: now())
    }

    // MARK: Loading

    /// Refreshes now, and once more when background busy copies have caught up.
    package func refreshAfterCopies() {
        _Concurrency.Task {
            await service.settled()
            await refresh()
        }
    }

    package func refresh() async {
        let window = period.interval(calendar: calendar)
        do {
            let loaded = try await service.snapshot(window: window)
            snapshot = loaded
            if calendar.firstWeekday != loaded.preferences.firstWeekday { calendar.firstWeekday = loaded.preferences.firstWeekday }
        } catch {
            self.error = Self.describe(error)
        }
        if let feed = taskFeed {
            tasks = await feed.tasks(agenda: agenda)
            dueMarks = await feed.dueMarks(in: window)
        }
    }

    package func syncNow() async {
        syncing = true
        await service.syncAll()
        syncing = false
        await refresh()
    }

    package func go(_ steps: Int) { period = period.moved(by: steps, calendar: calendar) }
    package func today() { period = CalendarPeriod(mode: period.mode, anchor: now()) }
    package func setMode(_ mode: CalendarViewMode) { period = CalendarPeriod(mode: mode, anchor: period.anchor) }
    package func select(collectionID: UUID?) { selectedCollectionID = collectionID }

    package var localCollectionID: UUID? {
        guard let snapshot else { return nil }
        let local = Set(snapshot.accounts.filter { $0.kind == .local }.map(\.id))
        return snapshot.collections.first { local.contains($0.accountID) }?.id
    }

    /// Where a new event goes unless the user picks another calendar.
    package var defaultCollectionID: UUID? {
        guard let snapshot else { return nil }
        if let last = snapshot.preferences.lastCollectionID, snapshot.collections.contains(where: { $0.id == last && $0.access == .write })
        {
            return last
        }
        return localCollectionID
    }

    package var writableCollections: [CalendarCollection] {
        guard let snapshot else { return [] }
        let live = Set(snapshot.accounts.filter { $0.state != .disabled }.map(\.id))
        return snapshot.collections.filter { $0.access == .write && live.contains($0.accountID) }
    }

    // MARK: What the grid shows

    /// Summary: originals of shown calendars. A calendar's view: its events and its busy copies.
    package func shownOccurrences() -> [CalendarOccurrence] {
        guard let snapshot else { return [] }
        if let selected = selectedCollectionID {
            return snapshot.occurrences.filter { $0.collectionID == selected }
        }
        let shown = Set(snapshot.collections.filter(\.shown).map(\.id))
        return snapshot.occurrences.filter { occurrence in
            shown.contains(occurrence.collectionID) && snapshot.events[occurrence.eventID]?.isBusyCopy == false
        }
    }

    package func visibleOccurrences(day: Date) -> [CalendarGridItem] {
        CalendarGridLayout.layout(day: day, occurrences: shownOccurrences(), calendar: calendar)
    }

    package func allDayRows(days: [Date]) -> [[CalendarOccurrence]] {
        CalendarGridLayout.allDay(days: days, occurrences: shownOccurrences(), calendar: calendar)
    }

    /// Working hours shade a calendar's own view only.
    package func workingHours(day: Date) -> [ClosedRange<Int>] {
        guard let selected = selectedCollectionID, let snapshot,
            let accountID = snapshot.collections.first(where: { $0.id == selected })?.accountID,
            let account = snapshot.accounts.first(where: { $0.id == accountID })
        else { return [] }
        let weekday = (calendar.component(.weekday, from: day) + 5) % 7 + 1
        return account.workingHours.days[weekday] ?? []
    }

    package func collection(_ id: UUID) -> CalendarCollection? { snapshot?.collections.first { $0.id == id } }
    package func event(_ id: UUID) -> CalendarEvent? { snapshot?.events[id] }

    // MARK: Writing

    package func create(_ draft: CalendarDraft) async {
        await perform(.create(draft), ignoringConflicts: false)
    }

    package func move(eventID: UUID, occurrenceKey: Date?, to time: CalendarEventTime, scope: CalendarEditScope) async {
        await perform(.move(eventID: eventID, occurrenceKey: occurrenceKey, time: time, scope: scope), ignoringConflicts: false)
    }

    package func update(eventID: UUID, occurrenceKey: Date?, draft: CalendarDraft, scope: CalendarEditScope) async {
        do {
            let outcome = try await service.update(
                eventID: eventID, occurrenceKey: occurrenceKey, draft: draft, scope: scope, ignoringConflicts: true)
            handle(outcome, pending: nil)
        } catch { self.error = Self.describe(error) }
        await refresh()
    }

    package func delete(eventID: UUID, occurrenceKey: Date?, scope: CalendarEditScope) async {
        do { try await service.delete(eventID: eventID, occurrenceKey: occurrenceKey, scope: scope) } catch {
            self.error = Self.describe(error)
        }
        await refresh()
    }

    /// A task dropped on the grid: its estimate (or an hour) at a 15-minute step,
    /// moved to the nearest free time the same day; with no room, the conflict question.
    package func dropTask(_ item: CalendarTaskItem, at start: Date) async {
        guard let collectionID = defaultCollectionID else { return }
        let minutes = max(15, item.estimateMinutes ?? 60)
        let dayStart = calendar.startOfDay(for: start)
        let offset = (start.timeIntervalSince(dayStart) / 900).rounded(.down) * 900
        var begin = dayStart.addingTimeInterval(offset)
        let length = TimeInterval(minutes * 60)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        if let free = try? await service.nearestFree(length: length, after: begin, collectionID: collectionID),
            free.addingTimeInterval(length) <= dayEnd
        {
            begin = free
        }
        let draft = CalendarDraft(
            collectionID: collectionID, title: item.title,
            time: .timed(
                start: begin, end: begin.addingTimeInterval(length),
                timeZone: calendar.timeZone.identifier == "GMT" ? nil : calendar.timeZone.identifier),
            taskID: item.id)
        await perform(.create(draft), ignoringConflicts: false)
    }

    package func resolveConflict(_ choice: CalendarConflictChoice) async {
        guard let prompt = conflict else { return }
        switch choice {
        case .writeAnyway:
            conflict = nil
            await perform(prompt.pending, ignoringConflicts: true)
        case .pickTime(let start):
            conflict = nil
            await perform(Self.shifted(prompt.pending, to: start), ignoringConflicts: false)
        case .writeToOrganizer(let item):
            var event = snapshot?.events[item.eventID]
            if event == nil { event = try? await service.store.event(id: item.eventID) }
            if let event, let organizer = event.organizerEmail { writeToOrganizer?(organizer, event.title) }
            conflict = nil
        case .decline(let item):
            conflict = nil
            do {
                try await service.respond(eventID: item.eventID, .declined)
                // The declined invitation's copies must be gone before the overlap is checked again.
                await service.settled()
                await perform(prompt.pending, ignoringConflicts: false)
            } catch {
                self.error = Self.describe(error)
                await refresh()
            }
        }
    }

    package func respond(eventID: UUID, _ response: CalendarResponse) async {
        do { try await service.respond(eventID: eventID, response) } catch { self.error = Self.describe(error) }
        await refresh()
    }

    package func check(attemptID: UUID) async {
        do {
            let state = try await service.check(attemptID: attemptID)
            notice = state == .confirmed ? "Сервер подтвердил запись." : "Сервер не нашёл запись."
        } catch { self.error = Self.describe(error) }
        await refresh()
    }

    package func dismiss(attemptID: UUID) async {
        do { try await service.dismiss(attemptID: attemptID) } catch { self.error = Self.describe(error) }
        await refresh()
    }

    // MARK: Accounts

    @discardableResult package func addGoogle() async -> Bool {
        await account { _ = try await self.service.addGoogleAccount(loginHint: nil) }
    }

    @discardableResult package func addCalDAV(name: String, server: URL, login: String, password: String) async -> Bool {
        await account { _ = try await self.service.addCalDAVAccount(name: name, server: server, login: login, password: password) }
    }

    @discardableResult package func addSubscription(name: String, url: URL) async -> Bool {
        await account { _ = try await self.service.addSubscription(name: name, url: url) }
    }

    package func reauthorize(accountID: UUID) async { await account { try await self.service.reauthorize(accountID: accountID) } }
    package func disconnect(accountID: UUID) async { await account { try await self.service.disconnect(accountID: accountID) } }

    private func account(_ body: @escaping () async throws -> Void) async -> Bool {
        defer { _Concurrency.Task { await self.refresh() } }
        do {
            try await body()
            return true
        } catch {
            self.error = Self.describe(error)
            return false
        }
    }

    // MARK: Settings

    package func setShown(collectionID: UUID, _ shown: Bool) async {
        guard var collection = collection(collectionID) else { return }
        collection.shown = shown
        await save(collection)
    }

    package func setDefaultReminder(collectionID: UUID, minutes: Int) async {
        guard var collection = collection(collectionID) else { return }
        collection.defaultReminderMinutes = max(0, minutes)
        await save(collection)
    }

    package func setColor(collectionID: UUID, _ color: String) async {
        guard var collection = collection(collectionID) else { return }
        collection.color = color
        await save(collection)
    }

    package func save(_ collection: CalendarCollection) async {
        do { try await service.updateCollection(collection) } catch { self.error = Self.describe(error) }
        await refresh()
    }

    package func setWorkingHours(accountID: UUID, _ hours: CalendarWorkingHours) async {
        guard var account = snapshot?.accounts.first(where: { $0.id == accountID }) else { return }
        account.workingHours = hours
        do { try await service.updateAccount(account) } catch { self.error = Self.describe(error) }
        await refresh()
    }

    package func savePreferences(_ change: (inout CalendarPreferences) -> Void) async {
        guard var preferences = snapshot?.preferences else { return }
        change(&preferences)
        do { try await service.savePreferences(preferences) } catch { self.error = Self.describe(error) }
        await refresh()
    }

    // MARK: Groups

    package func stage(collections: [CalendarCollection], groups: [CalendarGroup]) async {
        do {
            groupPreview = try await service.previewGroupChange(collections: collections, groups: groups)
            staged = (collections, groups)
        } catch { self.error = Self.describe(error) }
    }

    package func confirmGroupChange() async {
        guard let staged else { return }
        do { try await service.applyGroupChange(collections: staged.0, groups: staged.1) } catch { self.error = Self.describe(error) }
        self.staged = nil
        groupPreview = nil
        await refresh()
    }

    package func cancelGroupChange() {
        staged = nil
        groupPreview = nil
    }

    // MARK: Undo

    /// ⌘Z writes the previous time again; an event with attendees asks first.
    package func undoLastMove() async {
        guard let last = lastMove else { return }
        if last.shared, !undoNeedsConfirmation {
            undoNeedsConfirmation = true
            return
        }
        await confirmUndo()
    }

    package func confirmUndo() async {
        guard let last = lastMove else { return }
        undoNeedsConfirmation = false
        lastMove = nil
        do {
            _ = try await service.move(
                eventID: last.eventID, occurrenceKey: last.occurrenceKey, to: last.previous, scope: last.scope, ignoringConflicts: true)
        } catch { self.error = Self.describe(error) }
        await refresh()
    }

    package func cancelUndo() { undoNeedsConfirmation = false }

    // MARK: Plumbing

    private func perform(_ pending: CalendarPendingWrite, ignoringConflicts: Bool) async {
        do {
            switch pending {
            case .create(let draft):
                handle(try await service.create(draft, ignoringConflicts: ignoringConflicts), pending: pending)
            case .move(let eventID, let key, let time, let scope):
                let before = try await service.store.event(id: eventID)
                let outcome = try await service.move(
                    eventID: eventID, occurrenceKey: key, to: time, scope: scope, ignoringConflicts: ignoringConflicts)
                if case .conflicts = outcome {
                } else if let before {
                    lastMove = (eventID, key, before.time, scope, !before.attendees.isEmpty)
                }
                handle(outcome, pending: pending)
            }
            if let prompt = conflict, prompt.suggestion == nil, let collectionID = Self.collectionID(of: pending, snapshot: snapshot),
                let start = Self.start(of: pending)
            {
                let suggestion = try? await service.nearestFree(length: Self.length(of: pending), after: start, collectionID: collectionID)
                conflict = CalendarConflictPrompt(pending: pending, conflicts: prompt.conflicts, suggestion: suggestion)
            }
        } catch {
            self.error = Self.describe(error)
        }
        await refresh()
        refreshAfterCopies()
    }

    private func handle(_ outcome: CalendarWriteOutcome, pending: CalendarPendingWrite?) {
        switch outcome {
        case .saved: break
        case .conflicts(let found):
            if let pending { conflict = CalendarConflictPrompt(pending: pending, conflicts: found, suggestion: nil) }
        case .attemptOpen:
            notice = "Ответ сервера не получен. Запись не повторяется сама: проверьте её в карточке события."
        }
    }

    static func length(of pending: CalendarPendingWrite) -> TimeInterval {
        let time: CalendarEventTime
        switch pending {
        case .create(let draft): time = draft.time
        case .move(_, _, let value, _): time = value
        }
        if case .timed(let start, let end, _) = time { return end.timeIntervalSince(start) }
        return 86400
    }

    static func start(of pending: CalendarPendingWrite) -> Date? {
        let time: CalendarEventTime
        switch pending {
        case .create(let draft): time = draft.time
        case .move(_, _, let value, _): time = value
        }
        if case .timed(let start, _, _) = time { return start }
        return nil
    }

    static func collectionID(of pending: CalendarPendingWrite, snapshot: CalendarSnapshot?) -> UUID? {
        switch pending {
        case .create(let draft): draft.collectionID
        case .move(let eventID, _, _, _): snapshot?.events[eventID]?.collectionID
        }
    }

    static func shifted(_ pending: CalendarPendingWrite, to start: Date) -> CalendarPendingWrite {
        func shift(_ time: CalendarEventTime) -> CalendarEventTime {
            guard case .timed(let from, let to, let zone) = time else { return time }
            return .timed(start: start, end: start.addingTimeInterval(to.timeIntervalSince(from)), timeZone: zone)
        }
        switch pending {
        case .create(var draft):
            draft.time = shift(draft.time)
            return .create(draft)
        case .move(let id, let key, let time, let scope): return .move(eventID: id, occurrenceKey: key, time: shift(time), scope: scope)
        }
    }

    /// Readable Russian text; no server bodies, URLs or tokens ever reach it.
    package static func describe(_ error: Error) -> String {
        switch error as? CalendarFailure {
        case .invalidInput("local calendar has no attendees")?: "В локальном календаре нет участников: выберите внешний календарь."
        case .invalidInput("busy copy")?: "Плашку «Занято» меняет только её исходное событие."
        case .invalidInput("occurrence of shared series")?: "Одно вхождение встречи с участниками меняется в календаре организатора."
        case .invalidInput("read only")?: "Этот календарь только для чтения."
        case .invalidInput("https required")?: "Нужен адрес сервера по https."
        case .invalidInput("subscription url")?: "Ссылка на календарь должна начинаться с https:// или webcal://."
        case .invalidInput("other account")?: "Вход выполнен в другой аккаунт Google."
        case .invalidInput("google not configured")?: "Вход Google не настроен в этой сборке."
        case .invalidInput("attempt open")?: "Предыдущая запись этого события ещё не подтверждена."
        case .signInRequired?, .rejected(code: 401, _)?: "Нужно войти в учётную запись снова."
        case .adminBlocked?: "Администратор организации запретил Makosh доступ к этому аккаунту."
        case .unreachable?, .unknownOutcome?: "Сервер календаря недоступен."
        case .rejected(let code, _)?: "Сервер календаря отклонил запись (код \(code))."
        case .staleRevision?: "Событие изменилось. Обновите и повторите."
        default: "Календарь не выполнил действие."
        }
    }
}
