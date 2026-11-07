import MakoshTasks
import SwiftUI

/// The month calendar of the right column; dots, ranges and day filter arrive with the details task.
struct TaskCalendarPanel: View {
    @ObservedObject var model: TasksWorkspaceModel

    var body: some View {
        VStack(spacing: 6) {
            Text(model.calendarMonth.title).font(.caption.bold())
            Text("Календарь появится здесь.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity)
        .accessibilityIdentifier("tasks.calendar")
    }
}

/// The details panel: empty, several selected, or one task; the click-to-edit rows arrive with the details task.
struct TaskDetailsPanel: View {
    @ObservedObject var model: TasksWorkspaceModel

    var body: some View {
        if let selected = model.selected, let task = model.task(id: selected) {
            TaskDetailView(model: model, task: task)
        } else if model.selection.selected.count > 1 {
            VStack(spacing: 8) {
                Text(String(model.selection.selected.count)).font(.system(size: 40, weight: .bold)).foregroundStyle(Color.accentColor)
                Text("задач выбрано").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 32)).foregroundStyle(.quaternary)
                Text("Выберите задачу,\nчтобы увидеть детали").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("tasks.details.empty")
        }
    }
}
