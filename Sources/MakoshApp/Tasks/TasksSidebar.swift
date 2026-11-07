import MakoshTasks
import SwiftUI

/// Filters of «Мои» on top, lists and tags, then every Jira connection as its own space.
/// Rows toggle the combinable filters; the reference's full sidebar replaces this view later.
struct TasksSidebarView: View {
    @ObservedObject var model: TasksWorkspaceModel

    private enum Row: Hashable {
        case agenda(TasksAgenda)
        case status(TaskStatus?)
        case list(String)
        case tag(String)
        case jira(UUID)
    }

    private var selection: Binding<Row?> {
        Binding(
            get: {
                switch model.space {
                case .mine:
                    if let agenda = model.filters.agenda { return .agenda(agenda) }
                    if let list = model.filters.list { return .list(list) }
                    if let tag = model.filters.tag { return .tag(tag) }
                    return .status(model.filters.status)
                case .jira(let id): return .jira(id)
                }
            },
            set: { value in
                switch value {
                case .agenda(let agenda)?:
                    model.space = .mine
                    model.filters.toggle(agenda: agenda)
                case .status(let status)?:
                    model.space = .mine
                    if let status { model.filters.toggle(status: status) } else { model.filters.clearFilters() }
                case .list(let list)?:
                    model.space = .mine
                    model.filters.toggle(list: list)
                case .tag(let tag)?:
                    model.space = .mine
                    model.filters.toggle(tag: tag)
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
                    ForEach(TasksAgenda.allCases, id: \.self) { agenda in
                        row(agenda.title, agenda == .overdue ? "exclamationmark.triangle" : "calendar", model.agendaCounts[agenda] ?? 0)
                            .tag(Row.agenda(agenda)).accessibilityIdentifier("tasks.filter.\(agenda.rawValue)")
                    }
                }
                Section("Статус") {
                    row("Все", "line.3.horizontal.decrease.circle", model.totalCount).tag(Row.status(nil)).accessibilityIdentifier(
                        "tasks.filter.all")
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        row(TaskStyleText.status(status), symbol(status), model.statusCounts[status] ?? 0).tag(Row.status(status))
                            .accessibilityIdentifier("tasks.filter.status:\(status.rawValue)")
                    }
                }
                if !model.lists.isEmpty {
                    Section("Списки") {
                        ForEach(model.lists, id: \.self) { list in
                            row(list, "list.bullet", model.listCounts[list] ?? 0).tag(Row.list(list)).accessibilityIdentifier(
                                "tasks.filter.list:\(list)")
                        }
                    }
                }
                if !model.tags.isEmpty {
                    Section("Теги") {
                        ForEach(model.tags, id: \.self) { tag in
                            row("#" + tag, "number", model.tagCounts[tag] ?? 0).tag(Row.tag(tag)).accessibilityIdentifier(
                                "tasks.filter.tag:\(tag)")
                        }
                    }
                }
                Section {
                    if model.connections.isEmpty {
                        Text("Подключите Jira в Настройках → Задачи, чтобы видеть свои задачи здесь.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                    ForEach(model.connections) { connection in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(connection.name, systemImage: "rectangle.3.group")
                            Text(status(connection)).font(.caption).foregroundStyle(
                                connection.lastFailure == nil ? Color.secondary : Color.orange
                            ).lineLimit(1)
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
        let open = model.totalCount - (model.statusCounts[.done] ?? 0) - (model.statusCounts[.cancelled] ?? 0)
        return "\(open) открытых · \(model.agendaCounts[.today] ?? 0) сегодня"
    }

    private func symbol(_ status: TaskStatus) -> String {
        switch status {
        case .inbox: "tray"
        case .active: "bolt"
        case .done: "checkmark"
        case .cancelled: "xmark"
        }
    }

    private func row(_ title: String, _ symbol: String, _ count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(String(count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
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
