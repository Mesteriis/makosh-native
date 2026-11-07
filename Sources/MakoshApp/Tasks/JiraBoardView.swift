import MakoshTasks
import SwiftUI

/// A connection's issues in columns by workflow status; the card on the
/// right moves them through the transitions Jira allows.
struct JiraBoardView: View {
    @ObservedObject var model: TasksWorkspaceModel

    var body: some View {
        if model.visible.isEmpty {
            ContentUnavailableView(
                "Задач из Jira пока нет", systemImage: "rectangle.3.group",
                description: Text("Назначенные на вас и с упоминанием появятся после обновления.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.board) { column in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(column.title).font(.headline)
                                Spacer()
                                Text(String(column.tasks.count)).font(.caption).foregroundStyle(.secondary)
                            }.padding(.horizontal, 4)
                            ScrollView {
                                VStack(spacing: 8) {
                                    ForEach(column.tasks) { task in
                                        JiraBoardCard(model: model, task: task).onTapGesture { model.selected = task.id }
                                            .accessibilityIdentifier("tasks.board.\(task.code)")
                                    }
                                }
                            }
                        }
                        .padding(8).frame(width: 260).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityIdentifier("tasks.board.column.\(column.id)")
                    }
                }.padding(16)
            }
        }
    }
}

private struct JiraBoardCard: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task

    var body: some View {
        let observation = model.observation(id: task.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(observation?.issue.key ?? task.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                if let priority = observation?.issue.priority { Text(priority.name).font(.caption2).foregroundStyle(.secondary) }
            }
            Text(observation?.issue.summary ?? task.title).lineLimit(3)
            HStack(spacing: 6) {
                if task.source?.membership == .mentioned {
                    Label("упомянули", systemImage: "at").font(.caption2).foregroundStyle(.secondary)
                }
                if let due = observation?.issue.due { Text(TaskStyle.day(due)).font(.caption2).foregroundStyle(.secondary) }
                if let attempt = model.attempts(id: task.id).last, attempt.isOpen {
                    Label(attempt.state == .unknown ? "неизвестно" : "отправляется", systemImage: "clock").font(.caption2).foregroundStyle(
                        .orange)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(
            model.selected == task.id ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}
