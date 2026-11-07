import MakoshTasks
import SwiftUI

/// The day planner column; the grid, drops and slots arrive with their own task.
struct TaskPlannerView: View {
    @ObservedObject var model: TasksWorkspaceModel

    var body: some View {
        VStack {
            Text("Планер дня").font(.headline)
            Text("Сетка часов появится здесь.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("tasks.planner")
    }
}
