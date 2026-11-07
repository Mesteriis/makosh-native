import MakoshTasks
import SwiftUI

/// «Мои»: one row per task with the reference's keys — Space done/reopen,
/// S cycle, 1–4 priority, ⇧P postpone, ⌫ delete.
struct TaskListView: View {
    @ObservedObject var model: TasksWorkspaceModel

    var body: some View {
        List(selection: $model.selected) {
            ForEach(model.visible) { task in
                TaskRow(model: model, task: task).tag(task.id).accessibilityIdentifier("tasks.row.\(task.code)")
                    .contextMenu { TaskContextMenu(model: model, task: task) }
            }
        }
        .listStyle(.inset).scrollContentBackground(.hidden)
        .onKeyPress(.space) { handle { await model.toggleDone(id: $0) } }
        .onKeyPress(.delete) { handle { await model.delete(id: $0) } }
        .onKeyPress(characters: .init(charactersIn: "sSыЫ")) { _ in handle { await model.cycleStatus(id: $0) } }
        .onKeyPress(characters: .init(charactersIn: "1234")) { press in
            guard let value = Int(press.characters) else { return .ignored }
            return handle { await model.set(priority: value, id: $0) }
        }
        .onKeyPress(characters: .init(charactersIn: "pPзЗ"), phases: .down) { press in
            guard press.modifiers.contains(.shift) else { return .ignored }
            return handle { await model.postpone(id: $0) }
        }
    }

    private func handle(_ action: @escaping @MainActor (UUID) async -> Void) -> KeyPress.Result {
        guard let id = model.selected else { return .ignored }
        _Concurrency.Task { await action(id) }
        return .handled
    }
}

struct TaskRow: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task

    private var closed: Bool { task.status == .done || task.status == .cancelled }
    private var blockers: [Task] { model.blockers(task) }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                _Concurrency.Task { await model.toggleDone(id: task.id) }
            } label: {
                Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle").foregroundStyle(task.status == .done ? Color.green : .secondary)
            }
            .buttonStyle(.plain).help(task.status == .done ? "Открыть заново" : "Сделано").accessibilityIdentifier("tasks.row.done.\(task.code)")
            Text(task.code).font(.caption.monospaced()).foregroundStyle(.tertiary)
            Text("!\(task.priority)").font(.caption.bold()).foregroundStyle(TaskStyle.priority(task.priority))
            if !blockers.isEmpty {
                Image(systemName: "lock").foregroundStyle(.orange).help("Ждёт: " + blockers.map(\.title).joined(separator: ", "))
            }
            if let observation = model.observation(id: task.id) {
                Text(observation.issue.key).font(.caption.monospaced()).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                if task.source?.membership == .mentioned { Image(systemName: "at").foregroundStyle(.secondary).help("Вас упомянули") }
                if task.source?.membership == .kept { Image(systemName: "pin").foregroundStyle(.secondary).help("Оставлена в «Моих»") }
            }
            Text(task.title).strikethrough(closed).foregroundStyle(closed ? .secondary : .primary).lineLimit(1)
            Spacer()
            if let list = task.list { Text(list).font(.caption).foregroundStyle(.secondary) }
            ForEach(task.tags, id: \.self) { tag in Text("#" + tag).font(.caption).foregroundStyle(.secondary) }
            if let due = task.due {
                Text(TaskStyle.day(due)).font(.caption).foregroundStyle(model.isOverdue(task) ? Color.red : .secondary).monospacedDigit()
            }
            if model.timer?.taskID == task.id { Image(systemName: "timer").foregroundStyle(.green) }
        }
        .padding(.vertical, 2)
    }
}

struct TaskContextMenu: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task

    var body: some View {
        Menu("Статус") {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button(TaskStyle.statusTitle(status)) { _Concurrency.Task { await model.set(status: status, id: task.id) } }
            }
        }
        Menu("Приоритет") {
            ForEach(1...4, id: \.self) { value in Button("!\(value) \(TaskStyle.priorityTitle(value))") { _Concurrency.Task { await model.set(priority: value, id: task.id) } } }
        }
        Button("Отложить на день") { _Concurrency.Task { await model.postpone(id: task.id) } }
        if model.timer?.taskID != task.id { Button("Запустить таймер") { _Concurrency.Task { await model.startTimer(id: task.id) } } }
        if task.source != nil {
            if task.source?.membership == .kept {
                Button("Убрать из «Моих»") { _Concurrency.Task { await model.unkeep(id: task.id) } }
            } else if task.source?.membership == TaskMembership.none {
                Button("Оставить в «Моих»") { _Concurrency.Task { await model.keep(id: task.id) } }
            }
        }
        Divider()
        Button("Удалить", role: .destructive) { _Concurrency.Task { await model.delete(id: task.id) } }
    }
}

enum TaskStyle {
    static func priority(_ value: Int) -> Color {
        switch value {
        case 1: Color(red: 0.94, green: 0.27, blue: 0.27)
        case 2: Color(red: 0.98, green: 0.57, blue: 0.24)
        case 3: Color(red: 0.38, green: 0.65, blue: 0.98)
        default: Color.secondary
        }
    }
    static func priorityTitle(_ value: Int) -> String {
        switch value {
        case 1: "срочно"
        case 2: "высокий"
        case 3: "обычный"
        default: "без приоритета"
        }
    }
    static func statusTitle(_ status: TaskStatus) -> String {
        switch status {
        case .inbox: "Входящие"
        case .active: "В работе"
        case .done: "Сделано"
        case .cancelled: "Отменено"
        }
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM"
        return formatter.string(from: date)
    }
    static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours) ч \(minutes) мин" : "\(minutes) мин"
    }
    static func clock(_ seconds: Int) -> String { String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60) }
}

extension TasksWorkspaceModel {
    /// Space: done ↔ reopen (into active).
    func toggleDone(id: UUID) async {
        guard let task = task(id: id) else { return }
        await set(status: task.status == .done ? .active : .done, id: id)
    }
}
