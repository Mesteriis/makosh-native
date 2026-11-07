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

struct TasksContentView: View {
    @ObservedObject var model: TasksWorkspaceModel
    @FocusState private var quickEntryFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header.padding(16)
                Divider()
                switch model.space {
                case .mine:
                    if model.visible.isEmpty, model.tasks.isEmpty {
                        ContentUnavailableView(
                            "Задач пока нет", systemImage: "checklist",
                            description: Text("Напишите первую в строке выше: «Название @список #тег !1 ^завтра».")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.visible.isEmpty {
                        ContentUnavailableView(
                            "Здесь пусто", systemImage: "checklist", description: Text("Под этот фильтр ничего не попало.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TaskListView(model: model)
                    }
                case .jira:
                    JiraBoardView(model: model)
                }
                Divider()
                TaskTimerBar(model: model)
                if let message = model.error {
                    Divider()
                    HStack {
                        Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                        Spacer()
                        Button("Скрыть") { model.error = nil }.controlSize(.small)
                    }.padding(.horizontal, 16).padding(.vertical, 8).accessibilityIdentifier("tasks.error")
                }
            }
            if let selected = model.selected, let task = model.task(id: selected) {
                Divider()
                TaskDetailView(model: model, task: task).frame(width: 360).background { WorkspaceBackdrop(intensity: 0.55) }
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.selected)
        .task { model.startTicking() }
        .onDisappear { model.stopTicking() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if case .mine = model.space {
                    TaskQuickEntryField(model: model, focused: $quickEntryFocused)
                    Picker(
                        "Порядок",
                        selection: Binding(
                            get: { model.sortState?.field },
                            set: { field in model.sortState = field.map { TasksSortState(field: $0, descending: false) } })
                    ) {
                        Text("Название").tag(Optional<TasksSort>.none)
                        Text("Приоритет").tag(Optional(TasksSort.priority))
                        Text("Статус").tag(Optional(TasksSort.status))
                        Text("Срок").tag(Optional(TasksSort.due))
                        Text("Создание").tag(Optional(TasksSort.created))
                    }.frame(width: 130).accessibilityIdentifier("tasks.sort")
                    Toggle("Только актуальные", isOn: $model.filters.actualOnly).toggleStyle(.checkbox).accessibilityIdentifier(
                        "tasks.actualOnly")
                } else {
                    TextField("Поиск по ключу и названию", text: $model.search).textFieldStyle(.roundedBorder).accessibilityIdentifier(
                        "tasks.search")
                    Toggle("Ушедшие", isOn: $model.showLeft).toggleStyle(.checkbox).help("Задачи, которые перестали быть вашими")
                        .accessibilityIdentifier("tasks.showLeft")
                }
            }
            if let preview = model.quickEntryPreview { TaskQuickEntryPreview(entry: preview) }
        }
    }
}

/// One line that becomes a task; tokens are shown as they are recognised.
struct TaskQuickEntryField: View {
    @ObservedObject var model: TasksWorkspaceModel
    var focused: FocusState<Bool>.Binding
    @State private var text = ""

    var body: some View {
        TextField("Новая задача… (@список #тег !приоритет ^срок ~код)", text: $text)
            .textFieldStyle(.roundedBorder).focused(focused)
            .onChange(of: text) { _, value in model.previewQuickEntry(value) }
            .onSubmit {
                let value = text
                guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                text = ""
                _Concurrency.Task { await model.create(quickEntry: value) }
            }
            .accessibilityIdentifier("tasks.quickEntry")
            .background {
                Button("") { focused.wrappedValue = true }.keyboardShortcut("n", modifiers: .command).hidden()
            }
    }
}

struct TaskQuickEntryPreview: View {
    let entry: TaskQuickEntry

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<entry.tokens.count, id: \.self) { index in TaskTokenChip(token: entry.tokens[index]) }
            Spacer()
        }.accessibilityIdentifier("tasks.quickEntry.preview")
    }
}

private struct TaskTokenChip: View {
    let token: TaskQuickEntry.Token

    var body: some View {
        Text(token.text).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(token.resolved ? Color.primary : Color.orange)
            .help(hint)
    }

    private var color: Color {
        switch token.kind {
        case .text: .clear
        case .list: .blue
        case .tag: .green
        case .persona: .indigo
        case .priority: .red
        case .due: .orange
        case .recurrence: .teal
        case .flow: .pink
        case .dependency: .purple
        case .url: .cyan
        }
    }
    private var hint: String {
        guard !token.resolved else { return "" }
        switch token.kind {
        case .due: return "Дата не распознана — останется в названии."
        case .dependency: return "Задача не найдена — останется в названии."
        case .recurrence: return "Повтор не распознан — останется в названии."
        default: return ""
        }
    }
}

/// The running timer, today's and this week's totals, and undo.
struct TaskTimerBar: View {
    @ObservedObject var model: TasksWorkspaceModel

    var body: some View {
        HStack(spacing: 12) {
            if let timer = model.timer {
                Image(systemName: "timer").foregroundStyle(.green)
                Text(model.task(id: timer.taskID)?.title ?? "Задача").lineLimit(1)
                Text(TaskStyle.clock(model.timerElapsed)).monospacedDigit().accessibilityIdentifier("tasks.timer.elapsed")
                Button {
                    _Concurrency.Task { await model.stopTimer() }
                } label: {
                    Image(systemName: "stop.fill")
                }.help("Остановить и записать время").accessibilityIdentifier("tasks.timer.stop")
            } else {
                Text("Таймер не идёт").foregroundStyle(.secondary)
            }
            Spacer()
            Text("Сегодня \(TaskStyle.duration(model.summary.daySeconds)) · неделя \(TaskStyle.duration(model.summary.weekSeconds))").font(
                .caption
            )
            .foregroundStyle(.secondary).accessibilityIdentifier("tasks.summary")
            Button("Отменить") { _Concurrency.Task { await model.undo() } }.keyboardShortcut("z", modifiers: .command).controlSize(.small)
                .disabled(model.undoCount == 0).accessibilityIdentifier("tasks.undo")
        }.padding(.horizontal, 16).padding(.vertical, 8)
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
