import MakoshTasks
import SwiftUI

/// Filters of «Мои» on top, lists and tags, then every Jira connection as its own space.
struct TasksSidebarView: View {
    @ObservedObject var model: TasksWorkspaceModel

    private enum Row: Hashable {
        case filter(TasksFilter)
        case jira(UUID)
    }

    private var selection: Binding<Row?> {
        Binding(
            get: {
                switch model.space {
                case .mine: return .filter(model.filter)
                case .jira(let id): return .jira(id)
                }
            },
            set: { value in
                switch value {
                case .filter(let filter)?:
                    model.space = .mine
                    model.filter = filter
                case .jira(let id)?: model.space = .jira(id)
                case nil: break
                }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Задачи").font(.title2.bold())
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    _Concurrency.Task { await model.syncNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless).disabled(model.syncing || model.connections.isEmpty).help("Обновить из Jira")
                .accessibilityIdentifier("tasks.sync")
            }.padding(20)
            List(selection: selection) {
                Section("Повестка") {
                    row("Сегодня", "calendar", .today)
                    row("Завтра", "calendar.badge.clock", .tomorrow)
                    row("Неделя", "calendar", .week)
                    row("Месяц", "calendar", .month)
                    row("Просрочено", "exclamationmark.triangle", .overdue)
                }
                Section("Статус") {
                    row("Все", "line.3.horizontal.decrease.circle", .all)
                    row("Входящие", "tray", .status(.inbox))
                    row("В работе", "bolt", .status(.active))
                    row("Сделано", "checkmark", .status(.done))
                    row("Отменено", "xmark", .status(.cancelled))
                }
                if !model.lists.isEmpty {
                    Section("Списки") { ForEach(model.lists, id: \.self) { list in row(list, "list.bullet", .list(list)) } }
                }
                if !model.tags.isEmpty {
                    Section("Теги") { ForEach(model.tags, id: \.self) { tag in row("#" + tag, "number", .tag(tag)) } }
                }
                Section {
                    if model.connections.isEmpty {
                        Text("Подключите Jira в Настройках → Задачи, чтобы видеть свои задачи здесь.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.connections) { connection in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(connection.name, systemImage: "rectangle.3.group")
                            Text(status(connection)).font(.caption).foregroundStyle(connection.lastFailure == nil ? Color.secondary : Color.orange).lineLimit(1)
                        }
                        .tag(Row.jira(connection.id)).accessibilityIdentifier("tasks.jira.\(connection.id.uuidString)")
                    }
                } header: {
                    Text("Jira")
                }
            }.listStyle(.inset).scrollContentBackground(.hidden)
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private var subtitle: String {
        let open = model.count(.all) - model.count(.status(.done)) - model.count(.status(.cancelled))
        return "\(open) открытых · \(model.count(.today)) сегодня"
    }

    private func row(_ title: String, _ symbol: String, _ filter: TasksFilter) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(String(model.count(filter))).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(Row.filter(filter)).accessibilityIdentifier("tasks.filter.\(filter.key)")
    }

    private func status(_ connection: JiraConnection) -> String {
        if let failure = connection.lastFailure { return failure }
        guard let last = connection.lastSyncAt else { return "ещё не обновлялось" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        let when = formatter.localizedString(for: last, relativeTo: Date())
        return connection.mentionsUnavailable ? "обновлено \(when) · упоминания недоступны" : "обновлено \(when)"
    }
}
