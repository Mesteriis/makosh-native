import MakoshTasks
import SwiftUI

/// The reference's sidebar: agenda, status, lists, tags, personas, flows with
/// progress, the hotkeys table; settings below; the Jira connections last.
struct TasksSidebarView: View {
    @ObservedObject var model: TasksWorkspaceModel
    @Environment(\.openSettings) private var openSettings

    private static let sectionKeys = ["agenda", "status", "lists", "tags", "personas", "flows"]
    private var allExpanded: Bool { Self.sectionKeys.allSatisfy { !model.collapsedSections.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Задачи").font(.title2.bold())
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    let target = !allExpanded
                    for key in Self.sectionKeys {
                        if target { model.collapsedSections.remove(key) } else { model.collapsedSections.insert(key) }
                    }
                } label: {
                    Image(systemName: allExpanded ? "chevron.up.2" : "chevron.down.2")
                }.buttonStyle(.borderless).help(allExpanded ? "Свернуть все" : "Развернуть все").accessibilityIdentifier(
                    "tasks.sidebar.toggleAll")
            }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: model.condense ? 8 : 14) {
                    section("agenda", "Повестка", symbol: "calendar") {
                        ForEach(TasksAgenda.allCases, id: \.self) { agenda in
                            filterItem(
                                agenda.title, symbol: agenda == .overdue ? "exclamationmark.triangle" : "calendar",
                                count: model.agendaCounts[agenda] ?? 0, active: model.filters.agenda == agenda,
                                id: "tasks.filter.\(agenda.rawValue)"
                            ) {
                                model.space = .mine
                                model.filters.toggle(agenda: agenda)
                            }
                        }
                    }
                    section("status", "Статус") {
                        filterItem(
                            "Все", symbol: "line.3.horizontal.decrease.circle", count: model.totalCount,
                            active: model.filters.status == nil, id: "tasks.filter.all"
                        ) {
                            model.space = .mine
                            model.filters.status = nil
                        }
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            filterItem(
                                TaskStyleText.status(status), symbol: symbol(status), count: model.statusCounts[status] ?? 0,
                                active: model.filters.status == status, id: "tasks.filter.status:\(status.rawValue)"
                            ) {
                                model.space = .mine
                                model.filters.toggle(status: status)
                            }
                        }
                    }
                    if !model.lists.isEmpty {
                        section("lists", "Списки") {
                            ForEach(model.lists, id: \.self) { list in
                                filterItem(
                                    list, symbol: "list.bullet", count: model.listCounts[list] ?? 0, active: model.filters.list == list,
                                    id: "tasks.filter.list:\(list)"
                                ) {
                                    model.space = .mine
                                    model.filters.toggle(list: list)
                                }
                            }
                        }
                    }
                    if !model.tags.isEmpty {
                        section("tags", "Теги") {
                            ForEach(model.tags, id: \.self) { tag in
                                filterItem(
                                    tag, symbol: "number", count: model.tagCounts[tag] ?? 0, active: model.filters.tag == tag,
                                    id: "tasks.filter.tag:\(tag)"
                                ) {
                                    model.space = .mine
                                    model.filters.toggle(tag: tag)
                                }
                            }
                        }
                    }
                    if !model.personas.isEmpty {
                        section("personas", "Персоны") {
                            ForEach(model.personas, id: \.self) { persona in
                                filterItem(
                                    persona, symbol: "person", count: model.personaCounts[persona] ?? 0,
                                    active: model.filters.persona == persona, id: "tasks.filter.persona:\(persona)"
                                ) {
                                    model.space = .mine
                                    model.filters.toggle(persona: persona)
                                }
                            }
                        }
                    }
                    if !model.flows.isEmpty {
                        section("flows", "Цепочки") {
                            ForEach(model.flows, id: \.self) { flow in
                                let progress = model.flowProgress(flow)
                                let color = TaskStyle.color(model.flowMeta[flow]?.color)
                                VStack(spacing: 2) {
                                    filterItem(
                                        flow, symbol: "bolt", tint: color, count: model.flowCounts[flow] ?? 0,
                                        active: model.filters.flow == flow, id: "tasks.filter.flow:\(flow)"
                                    ) {
                                        model.space = .mine
                                        model.filters.toggle(flow: flow)
                                    }
                                    if progress.total > 0 {
                                        GeometryReader { geometry in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Color.white.opacity(0.08))
                                                Capsule().fill(color).frame(width: geometry.size.width * CGFloat(progress.percent) / 100)
                                            }
                                        }.frame(height: 4).padding(.horizontal, 10)
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    section("hotkeys", "Горячие клавиши", symbol: "keyboard") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Self.hotkeys, id: \.0) { key, text in
                                HStack(alignment: .top, spacing: 6) {
                                    Text(key).font(.caption2.monospaced()).padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
                                    Text(text).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.horizontal, 10)
                    }
                    Divider()
                    jira
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
            Divider()
            HStack {
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                }.buttonStyle(.borderless).help("Настройки → Задачи").accessibilityIdentifier("tasks.sidebar.settings")
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private var subtitle: String {
        let open = model.totalCount - (model.statusCounts[.done] ?? 0) - (model.statusCounts[.cancelled] ?? 0)
        return "\(open) открытых · \(model.agendaCounts[.today] ?? 0) сегодня"
    }

    private func section<Content: View>(
        _ key: String, _ title: String, symbol: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        let collapsed = model.collapsedSections.contains(key)
        return VStack(alignment: .leading, spacing: 2) {
            Button {
                if collapsed { model.collapsedSections.remove(key) } else { model.collapsedSections.insert(key) }
            } label: {
                HStack(spacing: 4) {
                    if let symbol { Image(systemName: symbol).font(.caption2) }
                    Text(title.uppercased()).font(.caption2.bold()).tracking(0.8)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2).rotationEffect(.degrees(collapsed ? 0 : 90))
                }.foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 2)
            }.buttonStyle(.plain).accessibilityIdentifier("tasks.sidebar.section.\(key)")
            if !collapsed { content() }
        }
    }

    private func filterItem(
        _ title: String, symbol: String, tint: Color? = nil, count: Int, active: Bool, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.caption).foregroundStyle(tint ?? (active ? TaskStyle.selection : Color.secondary))
                Text(title).lineLimit(1)
                Spacer()
                Text(String(count)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.callout).padding(.horizontal, 10).padding(.vertical, model.condense ? 2 : 5)
            .background(active ? TaskStyle.selection.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(active ? TaskStyle.selection : .primary)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }

    @ViewBuilder private var jira: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("JIRA").font(.caption2.bold()).tracking(0.8).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 2)
            if model.connections.isEmpty {
                Text("Подключите Jira в Настройках → Задачи, чтобы видеть свои задачи здесь.").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
            }
            ForEach(model.connections) { connection in
                let active = model.space == .jira(connection.id)
                Button {
                    model.space = .jira(connection.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(connection.name, systemImage: "rectangle.3.group").font(.callout)
                        Text(status(connection)).font(.caption2).foregroundStyle(
                            connection.lastFailure == nil ? Color.secondary : Color.orange
                        ).lineLimit(1)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                    .background(active ? TaskStyle.selection.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("tasks.jira.\(connection.id.uuidString)")
            }
        }
    }

    private func symbol(_ status: TaskStatus) -> String {
        switch status {
        case .inbox: "tray"
        case .active: "bolt"
        case .done: "checkmark"
        case .cancelled: "xmark"
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

    static let hotkeys: [(String, String)] = [
        ("⌘N", "Новая задача"), ("↑ / ↓", "Курсор"), ("⇧↑/↓", "Расширить выделение"), ("Home / End", "В начало / в конец"),
        ("⌘⇧A", "Выделить все"), ("Space", "Сделано / вернуть"), ("S", "Сменить статус"), ("Enter", "Открыть"), ("F2", "Переименовать"),
        ("⌫", "Удалить"), ("1 / 2 / 3 / 4", "Приоритет"), ("⇧P", "Отложить на день"), ("⌘C", "Скопировать ссылки"), ("⌘Z", "Отменить"),
        ("⌘E", "Поиск"), ("⌘D", "Планер"), ("Esc", "Снять выделение / поиск / фильтры"),
    ]
}
