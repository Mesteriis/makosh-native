import MakoshJira
import MakoshTasks
import SwiftUI

/// One task's details: the Jira card on top for a mirrored issue, then the
/// reference's rows with click-to-edit values, the notes, and the time block.
struct TaskDetailView: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    let onEdit: (UUID) -> Void
    @State private var editing: String?
    @State private var manualTime = false
    @State private var noteEditing: TaskNote?

    private var today: Date { Date() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Задача").font(.caption).foregroundStyle(.secondary)
                    Text(task.code).font(.caption2.monospaced()).foregroundStyle(.quaternary)
                    Spacer()
                    Button {
                        onEdit(task.id)
                    } label: {
                        Image(systemName: "doc.text")
                    }.buttonStyle(.borderless).help("Открыть для правки")
                        .accessibilityIdentifier("tasks.card.edit")
                }
                TaskEditableValue(id: "title", editing: $editing, display: task.title, value: task.title, font: .callout.weight(.medium)) {
                    value in
                    _Concurrency.Task { await model.rename(id: task.id, title: value) }
                }.accessibilityIdentifier("tasks.card.title")
                if let observation = model.observation(id: task.id), let connection = model.connection(for: task) {
                    Divider()
                    JiraIssueCard(model: model, task: task, observation: observation, connection: connection)
                }
                Divider()
                rows
                if !task.notes.isEmpty { notes }
                Divider()
                time
            }.padding(14)
        }
        .onChange(of: task.id) { _, _ in editing = nil }
        .sheet(isPresented: $manualTime) { ManualTimeSheet(model: model, task: task).makoshAppearance() }
        .sheet(item: $noteEditing) { note in TaskNoteEditor(model: model, task: task, note: note).makoshAppearance() }
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 0) {
            TaskDetailRow(symbol: statusSymbol, label: "Статус") {
                Picker(
                    "",
                    selection: Binding(
                        get: { task.status }, set: { value in _Concurrency.Task { await model.set(status: value, id: task.id) } })
                ) {
                    ForEach(TaskStatus.allCases, id: \.self) { Text(TaskStyleText.status($0)).tag($0) }
                }.labelsHidden().controlSize(.small).accessibilityIdentifier("tasks.card.status")
            }
            if model.isBlocked(task) {
                Label("Ждёт: " + model.blockers(task).map(\.title).joined(separator: ", "), systemImage: "lock").font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 6)
            }
            TaskDetailRow(symbol: "flag", label: "Приоритет") {
                Picker(
                    "",
                    selection: Binding(
                        get: { task.priority }, set: { value in _Concurrency.Task { await model.set(priority: value, id: task.id) } })
                ) {
                    ForEach(1...4, id: \.self) { Text("\($0) — \(TaskStyle.priorityTitle($0))").tag($0) }
                }.labelsHidden().controlSize(.small).accessibilityIdentifier("tasks.card.priority")
            }
            TaskDetailRow(symbol: "list.bullet", label: "Список") {
                TaskEditableValue(id: "list", editing: $editing, display: task.list, value: task.list ?? "", options: model.lists) {
                    value in
                    save { $0.list = value.isEmpty ? nil : value }
                }.accessibilityIdentifier("tasks.card.list")
            }
            TaskDetailRow(symbol: "number", label: "Теги") {
                TaskEditableValue(
                    id: "tags", editing: $editing, display: task.tags.isEmpty ? nil : task.tags.map { "#" + $0 }.joined(separator: " "),
                    value: task.tags.joined(separator: ", ")
                ) { value in
                    save {
                        $0.tags = value.split(separator: ",").map {
                            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
                        }.filter { !$0.isEmpty }
                    }
                }.accessibilityIdentifier("tasks.card.tags")
            }
            TaskDetailRow(symbol: "person", label: "Персоны") {
                TaskEditableValue(
                    id: "personas", editing: $editing, display: task.personas.isEmpty ? nil : task.personas.joined(separator: ", "),
                    value: task.personas.joined(separator: ", ")
                ) { value in
                    _Concurrency.Task { await model.setPersonas(id: task.id, TaskFieldInput.personas(value)) }
                }.accessibilityIdentifier("tasks.card.personas")
            }
            TaskDetailRow(symbol: "calendar", label: "Срок") {
                HStack(spacing: 6) {
                    TaskEditableValue(
                        id: "due", editing: $editing,
                        display: task.due.map { model.storedPreferences.dateFormat.string($0, calendar: model.calendar) },
                        value: task.due.map { TaskDateFormat.dmy.string($0, calendar: model.calendar) } ?? ""
                    ) { value in
                        if value.isEmpty {
                            save { $0.due = nil }
                        } else if let date = TaskFieldInput.date(value, today: today, calendar: model.calendar) {
                            save { $0.due = date }
                        }
                    }.accessibilityIdentifier("tasks.card.due")
                    if task.due != nil {
                        Button("+1 день") { _Concurrency.Task { await model.bulkPostpone(ids: [task.id]) } }.controlSize(.mini)
                            .accessibilityIdentifier("tasks.card.postpone")
                    }
                }
            }
            TaskDetailRow(symbol: "repeat", label: "Повтор") {
                TaskEditableValue(
                    id: "recurrence", editing: $editing, display: TaskRecurrence.humanText(task.recurrence), value: task.recurrence ?? "",
                    options: TaskRecurrence.keywords
                ) { value in
                    save { $0.recurrence = value.isEmpty ? nil : (TaskRecurrence.normalize(value) ?? $0.recurrence) }
                }.accessibilityIdentifier("tasks.card.recurrence")
            }
            TaskDetailRow(symbol: "bolt", label: "Цепочка") {
                TaskEditableValue(id: "flow", editing: $editing, display: task.flowID, value: task.flowID ?? "", options: model.flows) {
                    value in
                    _Concurrency.Task { await model.setFlow(id: task.id, name: value.isEmpty ? nil : value) }
                }.accessibilityIdentifier("tasks.card.flow")
            }
            if !task.dependsOn.isEmpty {
                TaskDetailRow(symbol: "arrow.turn.down.right", label: "Зависит от") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(task.dependsOn, id: \.self) { id in
                            HStack {
                                Text(model.task(id: id)?.title ?? "удалённая задача").font(.caption).foregroundStyle(.yellow).lineLimit(1)
                                Spacer()
                                Button {
                                    _Concurrency.Task { await model.removeDependency(id: task.id, on: id) }
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.plain).controlSize(.mini).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            TaskDetailRow(symbol: "link", label: "Ссылка") {
                HStack(spacing: 4) {
                    if let url = task.url, editing != "url" {
                        Link(url.host ?? url.absoluteString, destination: url).font(.caption).lineLimit(1)
                        Button {
                            editing = "url"
                        } label: {
                            Image(systemName: "pencil")
                        }.buttonStyle(.plain).controlSize(.mini).foregroundStyle(.secondary)
                    } else {
                        TaskEditableValue(
                            id: "url", editing: $editing, display: task.url?.absoluteString, value: task.url?.absoluteString ?? ""
                        ) { value in
                            if value.isEmpty { save { $0.url = nil } } else if let url = TaskFieldInput.url(value) { save { $0.url = url } }
                        }
                    }
                }.accessibilityIdentifier("tasks.card.url")
            }
            TaskDetailRow(symbol: "calendar.badge.clock", label: "Дата начала") {
                TaskEditableValue(
                    id: "start", editing: $editing,
                    display: task.start.map { model.storedPreferences.dateFormat.string($0, calendar: model.calendar) },
                    value: task.start.map { TaskDateFormat.dmy.string($0, calendar: model.calendar) } ?? ""
                ) { value in
                    if value.isEmpty {
                        save { $0.start = nil }
                    } else if let date = TaskFieldInput.date(value, today: today, calendar: model.calendar) {
                        save { $0.start = date }
                    }
                }.accessibilityIdentifier("tasks.card.start")
            }
            TaskDetailRow(symbol: "clock", label: "Оценка") {
                TaskEditableValue(
                    id: "estimate", editing: $editing, display: task.estimateMinutes.map(TaskFieldInput.estimateText),
                    value: task.estimateMinutes.map(TaskFieldInput.estimateText) ?? ""
                ) { value in
                    save { $0.estimateMinutes = value.isEmpty ? nil : (TaskFieldInput.estimateMinutes(value) ?? $0.estimateMinutes) }
                }.accessibilityIdentifier("tasks.card.estimate")
            }
            if task.postponed > 0 {
                TaskDetailRow(symbol: "arrow.uturn.right", label: "Переносов") {
                    Text("\(task.postponed)×").font(.caption).foregroundStyle(.secondary)
                }
            }
            TaskDetailRow(symbol: "calendar", label: "Создана") {
                Text(task.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            if let completed = task.completedAt {
                TaskDetailRow(symbol: "checkmark.circle", label: "Завершена") {
                    Text(completed.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusSymbol: String {
        switch task.status {
        case .inbox: "tray"
        case .active: "bolt"
        case .done: "checkmark"
        case .cancelled: "xmark"
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Заметки (\(task.notes.count))", systemImage: "doc.text").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ForEach(task.notes) { note in
                Text(note.content).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .onTapGesture(count: 2) { noteEditing = note }
                    .help("Двойной клик — править")
            }
        }
    }

    private var time: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Время").font(.headline)
                Spacer()
                if model.timer?.taskID == task.id {
                    Button("■ Остановить") { _Concurrency.Task { await model.stopTimer() } }.controlSize(.small).accessibilityIdentifier(
                        "tasks.card.timer.stop")
                } else {
                    Button("▶ Таймер") { _Concurrency.Task { await model.startTimer(id: task.id) } }.controlSize(.small)
                        .accessibilityIdentifier("tasks.card.timer.start")
                }
                Button("Вручную…") { manualTime = true }.controlSize(.small).accessibilityIdentifier("tasks.card.time.manual")
            }
            let entries = model.entries(id: task.id)
            if entries.isEmpty {
                Text("Время ещё не записывалось.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        Text(TaskStyle.duration(entry.seconds)).font(.caption.bold())
                        Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(Self.worklog(entry)).font(.caption2).foregroundStyle(
                            entry.worklogState == .deletedInJira ? .orange : .secondary)
                        if !entry.isLocked {
                            Button {
                                _Concurrency.Task { await model.deleteEntry(id: entry.id) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless).controlSize(.small)
                        }
                    }.accessibilityIdentifier("tasks.card.entry.\(entry.id.uuidString)")
                }
                Text("Всего: " + TaskStyle.duration(entries.filter { $0.worklogState != .deletedInJira }.reduce(0) { $0 + $1.seconds }))
                    .font(.caption)
            }
        }
    }

    private func save(_ change: (inout Task) -> Void) {
        var value = task
        change(&value)
        guard value != task else { return }
        _Concurrency.Task { await model.update(value) }
    }

    static func worklog(_ entry: TaskTimeEntry) -> String {
        switch entry.worklogState {
        case .none: entry.source == .meeting ? "встреча" : ""
        case .pending: "в Jira: отправляется"
        case .confirmed: "в Jira"
        case .deletedInJira: "удалено в Jira"
        }
    }
}

/// «значок · подпись · значение», as the reference lays the details out.
struct TaskDetailRow<Content: View>: View {
    let symbol: String
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A value that turns into a field on click; Enter or losing focus saves, Esc cancels.
struct TaskEditableValue: View {
    let id: String
    @Binding var editing: String?
    let display: String?
    let value: String
    var options: [String] = []
    var font: Font = .caption
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if editing == id {
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: $draft).textFieldStyle(.roundedBorder).controlSize(.small).focused($focused)
                    .onSubmit { finish(save: true) }
                    .onKeyPress(.escape) {
                        finish(save: false)
                        return .handled
                    }
                    .onChange(of: focused) { _, isFocused in if !isFocused, editing == id { finish(save: true) } }
                    .onAppear {
                        draft = value
                        focused = true
                    }
                if !options.isEmpty {
                    let matches = options.filter { draft.isEmpty || $0.localizedCaseInsensitiveContains(draft) }.prefix(5)
                    if !matches.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(matches), id: \.self) { option in
                                Button(option) {
                                    draft = option
                                    finish(save: true)
                                }.buttonStyle(.plain).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                            }
                        }
                    }
                }
            }
        } else {
            Text(display ?? "—").font(font).foregroundStyle(display == nil ? .tertiary : .primary).italic(display == nil)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .onTapGesture { editing = id }
        }
    }

    private func finish(save: Bool) {
        guard editing == id else { return }
        editing = nil
        if save, draft != value { commit(draft) }
    }
}

/// The reference's note window: a text box, ⌘⏎ saves, Esc cancels.
struct TaskNoteEditor: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    let note: TaskNote
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Заметка", systemImage: "doc.text").font(.headline)
            TextEditor(text: $text).font(.body).frame(minHeight: 180).padding(4)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6)).accessibilityIdentifier("tasks.note.text")
            HStack {
                Button("Удалить", role: .destructive) {
                    var value = task
                    value.notes.removeAll { $0.id == note.id }
                    dismiss()
                    _Concurrency.Task { await model.update(value) }
                }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { save() }.keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("tasks.note.save")
            }
        }
        .padding(16).frame(width: 480)
        .onAppear { text = note.content }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var value = task
        if let index = value.notes.firstIndex(where: { $0.id == note.id }) { value.notes[index].content = trimmed }
        dismiss()
        _Concurrency.Task { await model.update(value) }
    }
}

/// Hand-entered time for the selected task.
struct ManualTimeSheet: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    @Environment(\.dismiss) private var dismiss
    @State private var startedAt = Date()
    @State private var minutes = 30
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Записать время").font(.headline)
            Text(task.title).lineLimit(2)
            DatePicker("Начало", selection: $startedAt)
            Stepper("Минут: \(minutes)", value: $minutes, in: 1...1440, step: 5)
            TextField("Примечание", text: $note).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Далее") {
                    let value = (startedAt, minutes * 60, note)
                    dismiss()
                    _Concurrency.Task { await model.logManual(id: task.id, startedAt: value.0, seconds: value.1, note: value.2) }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("tasks.manual.next")
            }
        }.padding(16).frame(width: 400)
    }
}
