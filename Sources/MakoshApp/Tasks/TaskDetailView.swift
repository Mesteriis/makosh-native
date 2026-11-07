import MakoshJira
import MakoshTasks
import SwiftUI

/// The card: Jira on top for a mirrored issue, the local layer and time below.
struct TaskDetailView: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    @State private var title = ""
    @State private var notes = ""
    @State private var dependencyCode = ""
    @State private var manualTime = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(task.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.selected = nil
                    } label: {
                        Image(systemName: "xmark")
                    }.buttonStyle(.borderless).help("Закрыть карточку").accessibilityIdentifier("tasks.card.close")
                }
                if let observation = model.observation(id: task.id), let connection = model.connection(for: task) {
                    JiraIssueCard(model: model, task: task, observation: observation, connection: connection)
                    Divider()
                }
                localLayer
                Divider()
                time
            }.padding(16)
        }
        .onAppear(perform: load)
        .onChange(of: task.id) { _, _ in load() }
        .sheet(isPresented: $manualTime) {
            ManualTimeSheet(model: model, task: task).makoshAppearance()
        }
    }

    private func load() {
        title = task.title
        notes = task.notes
    }

    private var localLayer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Название", text: $title).textFieldStyle(.roundedBorder).font(.headline)
                .onSubmit { save { $0.title = title } }.accessibilityIdentifier("tasks.card.title")
            HStack {
                Picker(
                    "Статус",
                    selection: Binding(
                        get: { task.status }, set: { value in _Concurrency.Task { await model.set(status: value, id: task.id) } })
                ) {
                    ForEach(TaskStatus.allCases, id: \.self) { Text(TaskStyle.statusTitle($0)).tag($0) }
                }.accessibilityIdentifier("tasks.card.status")
                Picker(
                    "Приоритет",
                    selection: Binding(
                        get: { task.priority }, set: { value in _Concurrency.Task { await model.set(priority: value, id: task.id) } })
                ) {
                    ForEach(1...4, id: \.self) { Text("!\($0)").tag($0) }
                }.frame(width: 90).accessibilityIdentifier("tasks.card.priority")
            }
            if model.isBlocked(task) {
                Label("Ждёт: " + model.blockers(task).map(\.title).joined(separator: ", "), systemImage: "lock").font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Список") {
                TextField(
                    "без списка", text: Binding(get: { task.list ?? "" }, set: { value in save { $0.list = value.isEmpty ? nil : value } })
                )
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("tasks.card.list")
            }
            LabeledContent("Теги") {
                TextField(
                    "через запятую",
                    text: Binding(get: { task.tags.joined(separator: ", ") }, set: { value in save { $0.tags = Self.tags(value) } })
                ).textFieldStyle(.roundedBorder).accessibilityIdentifier("tasks.card.tags")
            }
            LabeledContent("Срок") {
                HStack {
                    DatePicker(
                        "", selection: Binding(get: { task.due ?? Date() }, set: { value in save { $0.due = value } }),
                        displayedComponents: .date
                    )
                    .labelsHidden().accessibilityIdentifier("tasks.card.due")
                    if task.due != nil { Button("Убрать") { save { $0.due = nil } }.controlSize(.small) }
                    Button("+1 день") { _Concurrency.Task { await model.postpone(id: task.id) } }.controlSize(.small)
                }
            }
            LabeledContent("Оценка, мин") {
                TextField(
                    "",
                    value: Binding(
                        get: { task.estimateMinutes ?? 0 }, set: { value in save { $0.estimateMinutes = value > 0 ? value : nil } }),
                    format: .number
                )
                .textFieldStyle(.roundedBorder).frame(width: 80).accessibilityIdentifier("tasks.card.estimate")
            }
            if let url = task.url { Link(url.absoluteString, destination: url).font(.caption).lineLimit(1) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Зависит от").font(.caption).foregroundStyle(.secondary)
                ForEach(task.dependsOn, id: \.self) { id in
                    HStack {
                        Text(model.task(id: id)?.title ?? "удалённая задача").lineLimit(1)
                        Spacer()
                        Button("Убрать") { _Concurrency.Task { await model.removeDependency(id: task.id, on: id) } }.controlSize(.small)
                    }
                }
                HStack {
                    TextField("Код задачи или ключ Jira", text: $dependencyCode).textFieldStyle(.roundedBorder).accessibilityIdentifier(
                        "tasks.card.dependency")
                    Button("Добавить") {
                        if let id = model.resolveReference(dependencyCode) {
                            dependencyCode = ""
                            _Concurrency.Task { await model.addDependency(id: task.id, on: id) }
                        } else {
                            model.error = "Задача не найдена."
                        }
                    }.controlSize(.small).disabled(dependencyCode.isEmpty)
                }
            }
            TextEditor(text: $notes).frame(minHeight: 80).font(.body).accessibilityIdentifier("tasks.card.notes")
                .onChange(of: notes) { _, value in if value != task.notes { save { $0.notes = value } } }
            if task.postponed > 0 { Text("Переносилось: \(task.postponed)").font(.caption).foregroundStyle(.secondary) }
            Text("Создана \(task.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
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
                            }.buttonStyle(.borderless).controlSize(.small)
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

    static func tags(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "") }.filter {
            !$0.isEmpty
        }
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
