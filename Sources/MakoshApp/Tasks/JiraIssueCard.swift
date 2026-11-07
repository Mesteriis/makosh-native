import MakoshJira
import MakoshTasks
import SwiftUI

/// The Jira half of the card. Task 16 adds the five actions; this shows
/// the issue as observed and the link into Jira.
struct JiraIssueCard: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    let observation: TaskProviderObservation
    let connection: JiraConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(observation.issue.key).font(.headline.monospaced())
                Text(observation.issue.status.name).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                Spacer()
                Link("Открыть в Jira", destination: observation.issue.browseURL).font(.caption).accessibilityIdentifier("tasks.jira.open")
            }
            Text(observation.issue.summary).font(.body.bold())
            HStack(spacing: 12) {
                Label(observation.issue.assignee?.displayName ?? "не назначена", systemImage: "person").font(.caption)
                if let priority = observation.issue.priority { Label(priority.name, systemImage: "flag").font(.caption) }
                if let due = observation.issue.due { Label(TaskStyle.day(due), systemImage: "calendar").font(.caption) }
            }.foregroundStyle(.secondary)
            if task.source?.membership == .mentioned { Label("Вас упомянули в комментариях", systemImage: "at").font(.caption).foregroundStyle(.orange) }
            if task.source?.membership == TaskMembership.none {
                Label("Перестала быть вашей · не обновляется с \(observation.observedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !observation.issue.descriptionText.isEmpty {
                Text(observation.issue.descriptionText).font(.callout).textSelection(.enabled).lineLimit(12)
            }
            HStack {
                Text("Проверено \(observation.observedAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Обновить") { _Concurrency.Task { await model.refreshIssue(id: task.id) } }.controlSize(.small).accessibilityIdentifier("tasks.jira.refresh")
            }
        }
    }
}
