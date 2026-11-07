import MakoshTasks
import SwiftUI

/// The section's content: quick entry, the list or the board, the timer
/// bar, and the card as a right-hand column when a task is selected.
struct TasksDetailView: View {
    @ObservedObject var host: TasksHost

    var body: some View {
        if let model = host.model {
            TasksContentView(model: model)
        } else if let failure = host.failure {
            ContentUnavailableView("Задачи недоступны", systemImage: "checklist", description: Text(failure)).frame(
                maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView("Открываем задачи…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The reference's layout inside the workspace's detail area: a header, the
/// list column, the planner (when shown), the right column with the
/// calendar and details, the status bar; toasts float over the list.
struct TasksContentView: View {
    @ObservedObject var model: TasksWorkspaceModel
    @FocusState private var quickEntryFocused: Bool
    @State private var plannerDragOrigin: Int?
    @State private var editingID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            TasksHeaderBar(model: model, quickEntryFocused: $quickEntryFocused)
            Divider()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    listColumn
                    if model.showPlanner, case .mine = model.space {
                        plannerDivider(total: geometry.size.width)
                        TaskPlannerView(model: model).frame(width: plannerWidth(total: geometry.size.width))
                    }
                    if case .jira = model.space {
                        if let selected = model.selected, let task = model.task(id: selected) {
                            Divider()
                            TaskDetailView(model: model, task: task) { editingID = $0 }.frame(width: 360).background {
                                WorkspaceBackdrop(intensity: 0.55)
                            }
                        }
                    } else if model.showRightPanel {
                        Divider()
                        TasksRightColumn(model: model) { editingID = $0 }.frame(width: rightColumnWidth).background {
                            WorkspaceBackdrop(intensity: 0.55)
                        }
                    }
                }
            }
            Divider()
            if let message = model.error {
                HStack {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Spacer()
                    Button("Скрыть") { model.error = nil }.controlSize(.small)
                }.padding(.horizontal, 16).padding(.vertical, 6).accessibilityIdentifier("tasks.error")
                Divider()
            }
            TasksStatusBar(model: model)
        }
        .animation(.easeInOut(duration: 0.2), value: model.selected)
        .animation(.easeInOut(duration: 0.2), value: model.showPlanner)
        .animation(.easeInOut(duration: 0.2), value: model.showRightPanel)
        .task {
            model.startTicking()
            await model.loadPlanner()
        }
        .onDisappear { model.stopTicking() }
        .sheet(item: Binding(get: { editingID.flatMap { model.task(id: $0) } }, set: { editingID = $0?.id })) { task in
            TaskEditDialog(model: model, task: task).makoshAppearance()
        }
    }

    /// 256 pt by the reference; 360 pt when a Jira task's card with its five actions is open.
    private var rightColumnWidth: CGFloat {
        if let selected = model.selected, model.task(id: selected)?.source != nil { return 360 }
        return 256
    }

    private func plannerWidth(total: CGFloat) -> CGFloat {
        let available = total - (model.showRightPanel ? rightColumnWidth : 0)
        return max(240, available * CGFloat(model.plannerWidthPercent) / 100)
    }

    private func plannerDivider(total: CGFloat) -> some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(width: 6)
            .overlay(Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if plannerDragOrigin == nil { plannerDragOrigin = model.plannerWidthPercent }
                        let available = total - (model.showRightPanel ? rightColumnWidth : 0)
                        let delta = Int(-value.translation.width / max(1, available) * 100)
                        model.plannerWidthPercent = max(20, min(60, (plannerDragOrigin ?? 40) + delta))
                    }
                    .onEnded { _ in plannerDragOrigin = nil }
            )
            .accessibilityIdentifier("tasks.planner.divider")
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            switch model.space {
            case .mine:
                VStack(spacing: 10) {
                    TaskQuickEntryField(model: model, focused: $quickEntryFocused)
                    if let preview = model.quickEntryPreview { TaskQuickEntryPreview(entry: preview) }
                    TaskFilterBar(model: model)
                }.padding(.horizontal, 16).padding(.vertical, 12)
                if model.visible.isEmpty, model.tasks.isEmpty {
                    ContentUnavailableView(
                        "Задач пока нет", systemImage: "checklist",
                        description: Text("Напишите первую в строке выше: «Название @список #тег !1 ^завтра».")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.visible.isEmpty {
                    ContentUnavailableView("Здесь пусто", systemImage: "checklist", description: Text("Под этот фильтр ничего не попало."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TaskListView(model: model, quickEntryFocused: $quickEntryFocused) { editingID = $0 }
                }
                if let flow = model.activeFlow, !model.flowTasks.isEmpty || model.flowMeta[flow] != nil {
                    TaskFlowView(model: model, flow: flow) { editingID = $0 }
                }
            case .jira:
                JiraBoardView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) { TasksToastStack(model: model) }
    }
}

/// What gets written when the timer stops or time is entered by hand.
struct TaskTimeDraftSheet: View {
    @ObservedObject var model: TasksWorkspaceModel
    @State var draft: TaskTimeDraft
    @State private var minutes: Int
    @State private var busy = false

    init(model: TasksWorkspaceModel, draft: TaskTimeDraft) {
        self.model = model
        _draft = State(initialValue: draft)
        _minutes = State(initialValue: max(1, draft.seconds / 60))
    }

    private var canSendToJira: Bool { model.task(id: draft.taskID)?.source != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.source == .timer ? "Записать время таймера" : draft.source == .meeting ? "Время встречи" : "Записать время").font(
                .headline)
            Text(model.task(id: draft.taskID)?.title ?? "").lineLimit(2)
            HStack {
                DatePicker("Начало", selection: $draft.startedAt).accessibilityIdentifier("tasks.draft.started")
                Stepper("Минут: \(minutes)", value: $minutes, in: 1...1440, step: 5).accessibilityIdentifier("tasks.draft.minutes")
            }
            TextField("Примечание", text: $draft.note).textFieldStyle(.roundedBorder).accessibilityIdentifier("tasks.draft.note")
            if canSendToJira { Toggle("Списать в Jira", isOn: $draft.sendToJira).accessibilityIdentifier("tasks.draft.sendToJira") }
            HStack {
                Spacer()
                Button(draft.source == .timer ? "Не записывать, таймер дальше" : "Отмена") {
                    _Concurrency.Task { await model.discardDraft() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Записать") {
                    busy = true
                    draft.seconds = minutes * 60
                    model.draft = draft
                    _Concurrency.Task { await model.confirmDraft() }
                }.keyboardShortcut(.defaultAction).disabled(busy).accessibilityIdentifier("tasks.draft.confirm")
            }
        }.padding(16).frame(width: 440)
    }
}

/// The sheets any section may raise: the time draft and the meeting-time
/// task chooser. Applied once per window, so Telemost can log time while
/// the Tasks section is not on screen.
struct TasksSheets: ViewModifier {
    @ObservedObject var host: TasksHost

    func body(content: Content) -> some View {
        if let model = host.model {
            content.modifier(TasksModelSheets(model: model))
        } else {
            content
        }
    }
}

private struct TasksModelSheets: ViewModifier {
    @ObservedObject var model: TasksWorkspaceModel

    func body(content: Content) -> some View {
        content
            .sheet(
                item: Binding(get: { model.draft }, set: { value in if value == nil { _Concurrency.Task { await model.discardDraft() } } })
            ) { draft in
                TaskTimeDraftSheet(model: model, draft: draft).makoshAppearance()
            }
            .sheet(item: Binding(get: { model.pendingMeetingTime }, set: { model.pendingMeetingTime = $0 })) { request in
                MeetingTimeChooserSheet(model: model, request: request).makoshAppearance()
            }
    }
}

/// Which task a meeting's time belongs to, when its title names no single key.
struct MeetingTimeChooserSheet: View {
    @ObservedObject var model: TasksWorkspaceModel
    let request: TaskMeetingTimeRequest
    @State private var query = ""

    private var candidates: [Task] {
        let needle = TasksWorkspaceModel.fold(query)
        return model.tasks.filter { task in
            guard task.deletedAt == nil, task.status != .cancelled, task.source?.membership != TaskMembership.none else { return false }
            guard !needle.isEmpty else { return true }
            let key = model.observation(id: task.id)?.issue.key.lowercased() ?? ""
            return TasksWorkspaceModel.fold(task.title).contains(needle) || key.contains(needle) || task.code.lowercased() == needle
        }.prefix(40).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Время встречи").font(.headline)
            Text("«\(request.title)» · \(TaskStyle.duration(request.seconds)). В какую задачу записать?").font(.callout)
            TextField("Название, код или ключ Jira", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier(
                "tasks.meeting.query")
            List(candidates) { task in
                Button {
                    _Concurrency.Task {
                        await model.logMeeting(
                            taskID: task.id, meetingID: request.meetingID, title: request.title, seconds: request.seconds,
                            startedAt: request.startedAt)
                    }
                } label: {
                    HStack {
                        if let key = model.observation(id: task.id)?.issue.key {
                            Text(key).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(task.title).lineLimit(1)
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("tasks.meeting.pick.\(task.code)")
            }.frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Отмена") { model.pendingMeetingTime = nil }.keyboardShortcut(.cancelAction)
            }
        }.padding(16).frame(width: 460)
    }
}
