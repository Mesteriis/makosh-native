import MakoshTasks
import SwiftUI

/// The section's header: the sidebar button, the expandable search, the
/// counters, and the planner / calendar / compact / right-panel toggles.
struct TasksHeaderBar: View {
    @ObservedObject var model: TasksWorkspaceModel
    var quickEntryFocused: FocusState<Bool>.Binding
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            headerToggle(
                "sidebar.left", on: model.showSidebar, tint: .accentColor, help: model.showSidebar ? "Скрыть панель" : "Показать панель"
            ) {
                model.showSidebar.toggle()
            }.accessibilityIdentifier("tasks.header.sidebar").tasksGuideAnchor("sidebar")
            search.tasksGuideAnchor("search")
            counters
            Spacer()
            if case .jira = model.space {
                Toggle("Ушедшие", isOn: $model.showLeft).toggleStyle(.checkbox).help("Задачи, которые перестали быть вашими")
                    .accessibilityIdentifier("tasks.showLeft")
            } else {
                headerToggle("clock", on: model.showPlanner, tint: .orange, help: "Планер дня (⌘D)") { model.showPlanner.toggle() }
                    .accessibilityIdentifier("tasks.header.planner")
                headerToggle("calendar", on: model.showCalendar && model.showRightPanel, tint: .purple, help: "Календарь") {
                    if !model.showRightPanel {
                        model.showRightPanel = true
                        model.showCalendar = true
                    } else {
                        model.showCalendar.toggle()
                    }
                }.accessibilityIdentifier("tasks.header.calendar")
                headerToggle("text.justify", on: model.condense, tint: .accentColor, help: model.condense ? "Просторнее" : "Компактнее") {
                    model.condense.toggle()
                }.accessibilityIdentifier("tasks.header.condense")
                headerToggle(
                    "sidebar.right", on: model.showRightPanel, tint: .accentColor,
                    help: model.showRightPanel ? "Скрыть детали" : "Показать детали"
                ) {
                    model.showRightPanel.toggle()
                }.accessibilityIdentifier("tasks.header.rightPanel")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background {
            // ⌘E and ⌘D of the reference.
            Button("") { expandSearch() }.keyboardShortcut("e", modifiers: .command).hidden()
            Button("") { model.showPlanner.toggle() }.keyboardShortcut("d", modifiers: .command).hidden()
        }
    }

    private var search: some View {
        HStack(spacing: 4) {
            Button {
                expandSearch()
            } label: {
                Image(systemName: "magnifyingglass")
            }.buttonStyle(.borderless)
                .accessibilityIdentifier("tasks.header.searchButton")
            if searchExpanded || !model.search.isEmpty {
                TextField(model.space == .mine ? "Поиск по названию, тегу, коду" : "Поиск по ключу и названию", text: $model.search)
                    .textFieldStyle(.plain).focused($searchFocused).frame(width: 300)
                    .onKeyPress(.escape) {
                        model.search = ""
                        searchExpanded = false
                        searchFocused = false
                        return .handled
                    }
                    .onChange(of: searchFocused) { _, focused in if !focused, model.search.isEmpty { searchExpanded = false } }
                    .accessibilityIdentifier("tasks.search")
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                        searchExpanded = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.white.opacity(searchExpanded || !model.search.isEmpty ? 0.08 : 0.03), in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeInOut(duration: 0.2), value: searchExpanded)
    }

    private func expandSearch() {
        searchExpanded = true
        DispatchQueue.main.async { searchFocused = true }
    }

    private var counters: some View {
        HStack(spacing: 4) {
            if let found = model.foundCount { Text("\(found) найдено ·").foregroundStyle(Color.accentColor) }
            Button("\(model.totalCount) \(TaskRecurrence.plural(model.totalCount, "задача", "задачи", "задач"))") { model.clearAll() }
                .buttonStyle(.plain).help("Сбросить фильтры").accessibilityIdentifier("tasks.header.total")
            Text("·")
            Button("\(model.doneCount) сделано") {
                model.filters.clearFilters()
                model.filters.status = .done
            }.buttonStyle(.plain).accessibilityIdentifier("tasks.header.done")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func headerToggle(_ symbol: String, on: Bool, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 22)
                .foregroundStyle(on ? tint : Color.secondary)
                .background(on ? tint.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).help(help)
    }
}

/// The right column: the month calendar (when shown) over the details panel.
struct TasksRightColumn: View {
    @ObservedObject var model: TasksWorkspaceModel
    let onEdit: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.showCalendar {
                TaskCalendarPanel(model: model)
                Divider()
            }
            TaskDetailsPanel(model: model, onEdit: onEdit)
        }
    }
}

/// The reference's status bar plus Makosh's timer and time totals.
struct TasksStatusBar: View {
    @ObservedObject var model: TasksWorkspaceModel

    private var today: Date { model.calendar.startOfDay(for: Date()) }
    private var activeToday: Int {
        model.tasks.filter {
            $0.deletedAt == nil && $0.status == .active && ($0.due.map { $0 < today.addingTimeInterval(86_400) } ?? false)
        }.count
    }
    private var doneToday: Int {
        model.tasks.filter { task in
            task.deletedAt == nil && task.status == .done && task.completedAt.map { model.calendar.isDate($0, inSameDayAs: today) } == true
        }.count
    }
    private var overdue: Int { model.agendaCounts[.overdue] ?? 0 }
    private var progress: (done: Int, total: Int) { (doneToday, activeToday + doneToday) }

    var body: some View {
        HStack(spacing: 10) {
            Text(model.storedPreferences.dateFormat.string(Date(), calendar: model.calendar)).foregroundStyle(.secondary)
            separator
            Text("\(model.totalCount) всего")
            Text("\(activeToday) активных")
            Text("\(doneToday) сделано").foregroundStyle(.green)
            if overdue > 0 { Text("\(overdue) просрочено").foregroundStyle(.red) }
            if progress.total > 0 {
                let percent = Int((Double(progress.done) / Double(progress.total) * 100).rounded())
                ProgressView(value: Double(progress.done), total: Double(progress.total)).progressViewStyle(.linear).frame(width: 60)
                    .tint(.green)
                Text("\(percent)%").foregroundStyle(.green)
            }
            if !model.connections.isEmpty {
                separator
                Text(jiraStatus).foregroundStyle(model.connections.contains { $0.lastFailure != nil } ? Color.orange : Color.secondary)
                    .lineLimit(1)
                Button {
                    _Concurrency.Task { await model.syncNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless).disabled(model.syncing).help("Обновить из Jira").accessibilityIdentifier("tasks.sync")
            }
            Spacer(minLength: 8)
            if model.showPlanner {
                let summary = model.plannerSummary
                Label(
                    "\(TasksStatusBar.hours(summary.planned)) / \(TasksStatusBar.hours(summary.available)) ч запланировано",
                    systemImage: "clock"
                ).foregroundStyle(.orange).accessibilityIdentifier("tasks.status.planner")
            }
            if let action = model.lastAction {
                Text(action).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 250, alignment: .trailing)
                    .accessibilityIdentifier("tasks.status.lastAction")
            }
            Button("⌘Z — отменить") { _Concurrency.Task { await model.undo() } }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .keyboardShortcut("z", modifiers: .command).disabled(model.undoCount == 0).opacity(model.undoCount == 0 ? 0.35 : 1)
                .accessibilityIdentifier("tasks.undo")
            Button {
                _Concurrency.Task { await model.setFocusEnabled(!model.focusEnabled) }
            } label: {
                Image(systemName: "timer").foregroundStyle(model.focusEnabled ? Color.red : Color.secondary)
            }.buttonStyle(.borderless).help(model.focusEnabled ? "Скрыть фокус-панель" : "Показать фокус-панель")
                .accessibilityIdentifier("tasks.status.focus")
            separator
            timer
            Text("Сегодня \(TaskStyle.duration(model.summary.daySeconds)) · неделя \(TaskStyle.duration(model.summary.weekSeconds))")
                .foregroundStyle(.secondary).accessibilityIdentifier("tasks.summary")
        }
        .font(.caption).padding(.horizontal, 12).padding(.vertical, 5).lineLimit(1)
    }

    private var separator: some View { Text("|").foregroundStyle(.quaternary) }

    private var jiraStatus: String {
        if let failure = model.connections.compactMap(\.lastFailure).first { return "Jira: " + failure }
        guard let last = model.connections.compactMap(\.lastSyncAt).max() else { return "Jira: ещё не обновлялось" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "Jira: обновлено " + formatter.string(from: last)
    }

    @ViewBuilder private var timer: some View {
        if let timer = model.timer {
            let seconds = model.focusEnabled ? model.focusState.workSeconds(of: timer.taskID, now: Date()) : model.timerElapsed
            Image(systemName: "timer").foregroundStyle(.green)
            Text(model.task(id: timer.taskID)?.title ?? "Задача").lineLimit(1).frame(maxWidth: 180, alignment: .leading)
            Text(TaskStyle.clock(seconds)).monospacedDigit().accessibilityIdentifier("tasks.timer.elapsed")
            if model.focusEnabled, !model.focusState.waiting.isEmpty {
                Text("ждут: \(model.focusState.waiting.count)").foregroundStyle(.orange)
            }
            Button {
                _Concurrency.Task { await model.stopTimer() }
            } label: {
                Image(systemName: "stop.fill")
            }.buttonStyle(.borderless).help("Остановить и записать время").accessibilityIdentifier("tasks.timer.stop")
        } else {
            Text("Таймер не идёт").foregroundStyle(.secondary)
            if model.focusEnabled, !model.focusState.waiting.isEmpty {
                Text("ждут: \(model.focusState.waiting.count)").foregroundStyle(.orange)
            }
        }
    }

    static func hours(_ minutes: Int) -> String {
        let value = Double(minutes) / 60
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }
}

/// Toasts of the last three seconds, stacked bottom-right over the list.
struct TasksToastStack: View {
    @ObservedObject var model: TasksWorkspaceModel

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(model.toasts) { toast in
                Text(toast.text).font(.callout).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))
                    .shadow(radius: 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.dismissToast(id: toast.id) }
            }
        }
        .padding(12).allowsHitTesting(!model.toasts.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: model.toasts.map(\.id))
        .accessibilityIdentifier("tasks.toasts")
    }
}
