import MakoshTasks
import SwiftUI

/// Sort chips and the active filters; the full bar with chips and flags arrives with the details task.
struct TaskFilterBar: View {
    @ObservedObject var model: TasksWorkspaceModel

    var body: some View {
        HStack(spacing: 8) {
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
            }.frame(width: 150).accessibilityIdentifier("tasks.sort")
            Toggle("Только актуальные", isOn: $model.filters.actualOnly).toggleStyle(.checkbox).accessibilityIdentifier("tasks.actualOnly")
            Spacer()
        }
    }
}
