import AppKit
import MakoshTasks
import SwiftUI
import UniformTypeIdentifiers

/// Row frames in the list's coordinate space, for the rubber band.
private struct TaskRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// Task ids dragged from the list into the planner.
struct TaskDragPayload: Codable, Transferable {
    let ids: [UUID]
    static var transferRepresentation: some TransferRepresentation { CodableRepresentation(contentType: .makoshTasks) }
}

extension UTType {
    static let makoshTasks = UTType(exportedAs: "org.makosh.tasks.ids")
}

private struct CopyTaskReferencesKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var copyTaskReferences: (() -> Void)? {
        get { self[CopyTaskReferencesKey.self] }
        set { self[CopyTaskReferencesKey.self] = newValue }
    }
}

/// ⌘C copies `to:КОД Название` lines while the task list has the focus.
struct TaskSelectionCommands: Commands {
    @FocusedValue(\.copyTaskReferences) private var copy
    var body: some Commands {
        CommandGroup(before: .pasteboard) {
            if let copy { Button("Скопировать ссылки на задачи", action: copy).keyboardShortcut("c", modifiers: .command) }
        }
    }
}

/// «Мои»: the reference's rows, cursor and selection, keys, rubber band,
/// context menu and the bulk bar.
struct TaskListView: View {
    @ObservedObject var model: TasksWorkspaceModel
    var quickEntryFocused: FocusState<Bool>.Binding
    let onEdit: (UUID) -> Void
    @FocusState private var listFocused: Bool
    @State private var renamingID: UUID?
    @State private var confirm: TaskConfirmation?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var dragStart: CGPoint?
    @State private var dragRect: CGRect?

    struct TaskConfirmation: Identifiable {
        let id = UUID()
        let ids: [UUID]
        let reopen: Bool
    }

    private var ids: [UUID] { model.visible.map(\.id) }
    private var condense: Bool { model.condense }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 14, height: 1)
                Text("Код / Jira").frame(width: TaskStyle.identifierWidth, alignment: .leading)
                Text("Задача")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.vertical, 6)
                .accessibilityIdentifier("tasks.list.columns")
            ScrollView {
                LazyVStack(spacing: condense ? 0 : 2) {
                    if model.overdueCount > 0 {
                        TaskSectionDivider(title: "Просрочено", count: model.overdueCount) {
                            model.selection.selected = Set(ids.prefix(model.overdueCount))
                        }
                        ForEach(Array(model.visible.prefix(model.overdueCount).enumerated()), id: \.element.id) { index, task in
                            row(task, index: index)
                        }
                        Color.clear.frame(height: 12)
                    }
                    let offset = model.overdueCount
                    ForEach(Array(model.flowGroups.enumerated()), id: \.offset) { groupIndex, group in
                        let start = offset + model.flowGroups.prefix(groupIndex).reduce(0) { $0 + $1.tasks.count }
                        if let flow = group.flow {
                            VStack(alignment: .leading, spacing: condense ? 0 : 2) {
                                Text(flow.uppercased()).font(.caption2.bold()).foregroundStyle(TaskStyle.color(model.flowMeta[flow]?.color))
                                    .padding(.leading, 4)
                                ForEach(Array(group.tasks.enumerated()), id: \.element.id) { index, task in row(task, index: start + index)
                                }
                            }
                            .padding(.vertical, 4)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(TaskStyle.color(model.flowMeta[flow]?.color).opacity(0.5)).frame(
                                    width: 2)
                            }
                        } else {
                            ForEach(Array(group.tasks.enumerated()), id: \.element.id) { index, task in row(task, index: start + index) }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 8)
            }
            .coordinateSpace(name: "tasksList")
            .onPreferenceChange(TaskRowFramesKey.self) { rowFrames = $0 }
            .overlay { if let dragRect { rubberBand(dragRect) } }
            .contentShape(Rectangle())
            .simultaneousGesture(rubberBandGesture)
            .onTapGesture { if dragStart == nil { model.selection.clear() } }
            .focusable().focused($listFocused).focusEffectDisabled()
            .focusedValue(\.copyTaskReferences, copyReferences)
            .modifier(
                TaskListKeys(
                    model: model, onEdit: onEdit, rename: { renamingID = $0 }, focusQuickEntry: { quickEntryFocused.wrappedValue = true })
            )
            .accessibilityIdentifier("tasks.list")
            if !model.selection.selected.isEmpty, model.storedPreferences.showBulkBar {
                TaskBulkBar(model: model).padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .alert(item: $confirm) { confirmation in
            Alert(
                title: Text(confirmationText(confirmation)),
                primaryButton: .default(Text("Да")) {
                    _Concurrency.Task { await model.bulk(status: confirmation.reopen ? .active : .done, ids: confirmation.ids) }
                },
                secondaryButton: .cancel(Text("Отмена")))
        }
    }

    private func confirmationText(_ confirmation: TaskConfirmation) -> String {
        let n = confirmation.ids.count
        if confirmation.reopen { return n == 1 ? "Отменить завершение задачи?" : "Отменить завершение \(n) задач?" }
        return n == 1 ? "Завершить задачу?" : "Завершить \(TasksWorkspaceModel.tasksCount(n))?"
    }

    private func row(_ task: Task, index: Int) -> some View {
        TaskRowView(
            model: model, task: task, isCursor: model.selection.cursor == index, isSelected: model.selection.selected.contains(task.id),
            isRenaming: renamingID == task.id, hideStatus: model.filters.status != nil,
            onRename: { title in
                renamingID = nil
                _Concurrency.Task { await model.rename(id: task.id, title: title) }
            },
            onRenameCancel: { renamingID = nil },
            onCheckbox: { checkbox(task) }
        )
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: TaskRowFramesKey.self, value: [task.id: geometry.frame(in: .named("tasksList"))])
            }
        }
        .onTapGesture(count: 2) { onEdit(task.id) }
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.selection.click(index: index, id: task.id, shift: flags.contains(.shift), command: flags.contains(.command), visible: ids)
            listFocused = true
        }
        .contextMenu { TaskContextMenu(model: model, task: task, onEdit: onEdit) }
        .tasksGuideAnchor(index == 0 ? "task-row" : "task-row-\(index)")
        .draggable(
            TaskDragPayload(
                ids: model.selection.selected.contains(task.id) ? ids.filter { model.selection.selected.contains($0) } : [task.id])
        )
        .accessibilityIdentifier("tasks.row.\(task.code)")
    }

    private func checkbox(_ task: Task) {
        let targets = model.selection.selected.count > 1 && model.selection.selected.contains(task.id) ? model.targets : [task.id]
        let reopen = task.status == .done
        if !reopen, targets.allSatisfy({ model.task(id: $0).map { model.isBlocked($0) } ?? false }) {
            model.toast("Заблокировано: сначала закройте зависимости")
            return
        }
        confirm = TaskConfirmation(ids: targets, reopen: reopen)
    }

    private func copyReferences() {
        let text = model.referencesText(ids: model.targets)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.toast("Скопировано: " + TasksWorkspaceModel.tasksCount(model.targets.count))
    }

    // MARK: Rubber band

    private var rubberBandGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("tasksList"))
            .onChanged { value in
                if dragStart == nil {
                    // A drag that starts on a row is the row's own drag (into the planner), not a rubber band.
                    guard !rowFrames.values.contains(where: { $0.contains(value.startLocation) }) else { return }
                    dragStart = value.startLocation
                }
                let origin = dragStart ?? value.startLocation
                let rect = CGRect(
                    x: min(origin.x, value.location.x), y: min(origin.y, value.location.y), width: abs(value.location.x - origin.x),
                    height: abs(value.location.y - origin.y))
                dragRect = rect
                model.selection.selected = Set(rowFrames.filter { $0.value.intersects(rect) }.map(\.key))
            }
            .onEnded { _ in
                dragStart = nil
                dragRect = nil
                listFocused = true
            }
    }

    private func rubberBand(_ rect: CGRect) -> some View {
        Rectangle().fill(TaskStyle.selection.opacity(0.06))
            .overlay(Rectangle().strokeBorder(TaskStyle.selection.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY).allowsHitTesting(false)
    }
}

/// The reference's keys while the list has the focus.
private struct TaskListKeys: ViewModifier {
    @ObservedObject var model: TasksWorkspaceModel
    let onEdit: (UUID) -> Void
    let rename: (UUID) -> Void
    let focusQuickEntry: () -> Void

    private var ids: [UUID] { model.visible.map(\.id) }
    private var single: UUID? {
        if let cursor = model.selection.cursor, ids.indices.contains(cursor) { return ids[cursor] }
        return model.selection.selected.count == 1 ? model.selection.selected.first : nil
    }

    func body(content: Content) -> some View {
        content
            .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
                model.selection.move(by: press.key == .downArrow ? 1 : -1, extend: press.modifiers.contains(.shift), visible: ids)
                return .handled
            }
            .onKeyPress(keys: [.home, .end], phases: .down) { press in
                model.selection.jump(toStart: press.key == .home, extend: press.modifiers.contains(.shift), visible: ids)
                return .handled
            }
            .onKeyPress(.space) { act { await model.bulkToggleDone(ids: $0) } }
            .onKeyPress(characters: .init(charactersIn: "sSыЫ")) { _ in act { await model.bulkCycle(ids: $0) } }
            .onKeyPress(characters: .init(charactersIn: "1234")) { press in
                guard let value = Int(press.characters) else { return .ignored }
                return act { await model.bulkPriority(value, ids: $0) }
            }
            .onKeyPress(characters: .init(charactersIn: "pPзЗ"), phases: .down) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                return act { await model.bulkPostpone(ids: $0) }
            }
            .onKeyPress(characters: .init(charactersIn: "aAфФ"), phases: .down) { press in
                guard press.modifiers.contains(.command), press.modifiers.contains(.shift) else { return .ignored }
                model.selection.selectAll(visible: ids)
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in act { await model.bulkDelete(ids: $0) } }
            .onKeyPress(.return) {
                guard let id = single else { return .ignored }
                onEdit(id)
                return .handled
            }
            .onKeyPress(KeyEquivalent(Character(UnicodeScalar(0xF705)!))) {  // F2
                guard let id = single else { return .ignored }
                rename(id)
                return .handled
            }
            .onKeyPress(.escape) {
                model.escape()
                return .handled
            }
            .onKeyPress(.tab) {
                focusQuickEntry()
                return .handled
            }
    }

    private func act(_ action: @escaping @MainActor ([UUID]) async -> Void) -> KeyPress.Result {
        let targets = model.targets
        guard !targets.isEmpty else { return .ignored }
        _Concurrency.Task { await action(targets) }
        return .handled
    }
}

/// «Просрочено N» above the floated rows; a click selects them all.
struct TaskSectionDivider: View {
    let title: String
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title.uppercased(), systemImage: "exclamationmark.triangle").font(.caption.bold()).foregroundStyle(TaskStyle.overdue)
                Text(String(count)).font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(TaskStyle.overdue.opacity(0.15), in: Capsule()).foregroundStyle(TaskStyle.overdue)
                Rectangle().fill(TaskStyle.overdue.opacity(0.2)).frame(height: 1)
            }
        }.buttonStyle(.plain).padding(.vertical, 2).accessibilityIdentifier("tasks.overdueDivider")
    }
}

/// One row: checkbox, badges, title, tags, due, markers; the stripe shows selection or overdue.
struct TaskRowView: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    let isCursor: Bool
    let isSelected: Bool
    let isRenaming: Bool
    let hideStatus: Bool
    let onRename: (String) -> Void
    let onRenameCancel: () -> Void
    let onCheckbox: () -> Void
    @State private var hovered = false
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    private var closed: Bool { task.status == .done || task.status == .cancelled }
    private var blocked: Bool { !closed && model.isBlocked(task) }
    private var overdue: Bool { model.isOverdue(task) }
    private var stripe: Color? { isSelected ? TaskStyle.selection : overdue ? TaskStyle.overdue : nil }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onCheckbox) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).stroke(
                        task.status == .done ? Color.green : Color.secondary.opacity(0.7), lineWidth: 1
                    )
                    .background(RoundedRectangle(cornerRadius: 3).fill(task.status == .done ? Color.green : Color.clear))
                    .frame(width: 14, height: 14)
                    if task.status == .done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                }
            }
            .padding(.top, 2)
            .buttonStyle(.plain).help(task.status == .done ? "Отменить завершение" : "Завершить").accessibilityIdentifier(
                "tasks.row.done.\(task.code)")
            VStack(alignment: .leading, spacing: 3) {
                Text(task.code).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .accessibilityLabel("Код задачи: \(task.code)")
                if let observation = model.observation(id: task.id) {
                    Text(observation.issue.key).font(.system(.caption, design: .monospaced))
                        .foregroundStyle(WorkspaceStyle.accent).lineLimit(1).truncationMode(.middle)
                        .help(observation.issue.key).accessibilityLabel("Jira: \(observation.issue.key)")
                }
            }
            .frame(width: TaskStyle.identifierWidth, alignment: .leading)
            .accessibilityIdentifier("tasks.row.identity.\(task.code)")
            VStack(alignment: .leading, spacing: model.condense ? 2 : 5) {
                title.frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    metadata.fixedSize(horizontal: true, vertical: false)
                    compactMetadata
                }
                if !model.condense {
                    let details =
                        ([task.list].compactMap { $0 } + task.personas.map { "/" + $0 }
                        + task.tags.map { "#" + $0 } + [task.flowID].compactMap { $0 }).joined(separator: " · ")
                    if !details.isEmpty {
                        Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(details)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)

        }
        .padding(.horizontal, 10).padding(.vertical, model.condense ? 3 : 7)
        .frame(minHeight: model.condense ? 44 : 70, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(
                isSelected ? TaskStyle.selection.opacity(0.08) : hovered ? Color.white.opacity(0.04) : Color.clear)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(TaskStyle.selection.opacity(isCursor ? (isSelected ? 0.35 : 0.25) : 0), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            if let stripe { RoundedRectangle(cornerRadius: 2).fill(stripe).frame(width: 3).padding(.vertical, 2) }
        }
        .opacity(closed ? 0.75 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                draft = task.title
                renameFocused = true
            }
        }
    }

    @ViewBuilder private var title: some View {
        if isRenaming {
            TextField("", text: $draft).textFieldStyle(.plain).focused($renameFocused)
                .onSubmit { commitRename() }
                .onKeyPress(.escape) {
                    onRenameCancel()
                    return .handled
                }
                .onChange(of: renameFocused) { _, focused in if !focused, isRenaming { commitRename() } }
                .accessibilityIdentifier("tasks.row.rename")
        } else {
            Text(task.title).strikethrough(task.status == .done)
                .foregroundStyle(closed ? .secondary : .primary).lineLimit(1)
                .help(task.title).accessibilityIdentifier("tasks.row.title.\(task.code)")
        }
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            if !hideStatus {
                TaskStatusBadge(status: task.status) { _Concurrency.Task { await model.bulkCycle(ids: [task.id]) } }
                    .frame(width: TaskStyle.statusWidth, alignment: .leading)
            }
            TaskPriorityBadge(priority: task.priority).frame(width: 36, alignment: .leading)
                .help("Приоритет: " + TaskStyle.priorityTitle(task.priority))
            if let due = task.due {
                Label(model.storedPreferences.dateFormat.string(due, calendar: model.calendar), systemImage: "calendar")
                    .font(.caption).monospacedDigit().lineLimit(1)
                    .foregroundStyle(closed ? Color.secondary : overdue ? TaskStyle.overdue : TaskStyle.due)
            }
            if blocked {
                Image(systemName: "lock").foregroundStyle(.yellow)
                    .help("Ждёт: " + model.blockers(task).map(\.title).joined(separator: ", "))
            } else if !task.dependsOn.isEmpty && !closed {
                Image(systemName: "checkmark").foregroundStyle(.green).help("Зависимости выполнены")
            }
            if model.plannedTaskIDs.contains(task.id) { Image(systemName: "clock").help("В планере") }
            if let recurrence = task.recurrence {
                Image(systemName: "repeat").help(TaskRecurrence.humanText(recurrence) ?? recurrence)
            }
            if !task.notes.isEmpty { Image(systemName: "doc.text").help(String(task.notesText.prefix(500))) }
            if task.source?.membership == .mentioned { Image(systemName: "at").help("Вас упомянули") }
            if task.source?.membership == .kept { Image(systemName: "pin").help("Оставлена в «Моих»") }
            if model.timer?.taskID == task.id { Image(systemName: "timer").foregroundStyle(.green) }
            Spacer(minLength: 0)
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private var compactMetadata: some View {
        HStack(spacing: 6) {
            if !hideStatus {
                TaskStatusBadge(status: task.status) { _Concurrency.Task { await model.bulkCycle(ids: [task.id]) } }
                    .labelStyle(.iconOnly).help(TaskStyle.statusTitle(task.status))
            }
            TaskPriorityBadge(priority: task.priority).help("Приоритет: " + TaskStyle.priorityTitle(task.priority))
            if let due = task.due {
                Text(TaskStyle.day(due)).font(.caption).lineLimit(1)
                    .foregroundStyle(overdue ? TaskStyle.overdue : TaskStyle.due)
            }
            if blocked { Image(systemName: "lock").font(.caption).help("Заблокирована зависимостями") }
            Spacer(minLength: 0)
        }
    }

    private func commitRename() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == task.title { onRenameCancel() } else { onRename(value) }
    }
}

struct TaskStatusBadge: View {
    let status: TaskStatus
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(TaskStyleText.status(status), systemImage: symbol).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                .background(TaskStyle.status(status).opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(TaskStyle.status(status).opacity(0.4)))
                .foregroundStyle(TaskStyle.status(status))
        }.buttonStyle(.plain).help("Следующий статус")
    }

    private var symbol: String {
        switch status {
        case .inbox: "tray"
        case .active: "bolt"
        case .done: "checkmark"
        case .cancelled: "xmark"
        }
    }
}

struct TaskPriorityBadge: View {
    let priority: Int

    var body: some View {
        Label(String(priority), systemImage: "flag").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2)
            .background(TaskStyle.priority(priority), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
    }
}

/// Right-click: statuses, open, focus, the snooze rows, duplicate, references, delete.
struct TaskContextMenu: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    let onEdit: (UUID) -> Void

    private var multi: Bool { model.selection.selected.count > 1 && model.selection.selected.contains(task.id) }
    private var ids: [UUID] { multi ? model.targets : [task.id] }

    var body: some View {
        if multi { Text("Выбрано \(ids.count)") }
        Menu("Статус") {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button(TaskStyleText.status(status)) { _Concurrency.Task { await model.bulk(status: status, ids: ids) } }
            }
        }
        if !multi {
            Button("Открыть") { onEdit(task.id) }
            Button("В фокус") {
                _Concurrency.Task {
                    if !model.focusEnabled { await model.setFocusEnabled(true) }
                    await model.focus(id: task.id)
                }
            }
        }
        Divider()
        Button("На сегодня") { _Concurrency.Task { await model.bulkToday(ids: ids) } }
        Button("Отложить на день") { _Concurrency.Task { await model.bulkPostpone(ids: ids) } }
        Button("До понедельника") { _Concurrency.Task { await model.bulkSnooze(ids: ids, until: .monday) } }
        Button("До вторника") { _Concurrency.Task { await model.bulkSnooze(ids: ids, until: .tuesday) } }
        Button("На неделю") { _Concurrency.Task { await model.bulkSnooze(ids: ids, days: 7, months: 0) } }
        Button("На месяц") { _Concurrency.Task { await model.bulkSnooze(ids: ids, days: 0, months: 1) } }
        Divider()
        if !multi { Button("Дублировать") { _Concurrency.Task { await model.duplicate(id: task.id) } } }
        Button("Скопировать ссылки") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.referencesText(ids: ids), forType: .string)
            model.toast("Скопировано: " + TasksWorkspaceModel.tasksCount(ids.count))
        }
        if task.source != nil, !multi {
            if task.source?.membership == .kept {
                Button("Убрать из «Моих»") { _Concurrency.Task { await model.unkeep(id: task.id) } }
            } else if task.source?.membership == TaskMembership.none {
                Button("Оставить в «Моих»") { _Concurrency.Task { await model.keep(id: task.id) } }
            }
        }
        Divider()
        Button(multi ? "Удалить выбранные" : "Удалить", role: .destructive) { _Concurrency.Task { await model.bulkDelete(ids: ids) } }
    }
}

/// «N выбрано · Выполнить · Статус · Сегодня · +1 день · Удалить · ×»
struct TaskBulkBar: View {
    @ObservedObject var model: TasksWorkspaceModel

    private var ids: [UUID] { model.targets }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(ids.count) выбрано").font(.callout.bold()).foregroundStyle(TaskStyle.selection).fixedSize()
            Spacer()
            bulkButton("Выполнить", tint: .green) { await model.bulkToggleDone(ids: ids) }
            Menu("Ещё") {
                Button("Статус") { _Concurrency.Task { await model.bulkCycle(ids: ids) } }
                Button("Сегодня") { _Concurrency.Task { await model.bulkToday(ids: ids) } }
                Button("Отложить на день") { _Concurrency.Task { await model.bulkPostpone(ids: ids) } }
                Button("Удалить", role: .destructive) { _Concurrency.Task { await model.bulkDelete(ids: ids) } }
            }.fixedSize().help("Другие действия с выбранными задачами")
            Button {
                model.selection.clear()
            } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(TaskStyle.selection.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(TaskStyle.selection.opacity(0.3)))
        .accessibilityIdentifier("tasks.bulkBar")
    }

    private func bulkButton(_ title: String, tint: Color, action: @escaping @MainActor () async -> Void) -> some View {
        Button(title) { _Concurrency.Task { await action() } }.buttonStyle(.plain).font(.caption).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 4).background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint.opacity(0.3))).foregroundStyle(tint)
    }
}

enum TaskStyle {
    static let identifierWidth: CGFloat = 84
    static let statusWidth: CGFloat = 100
    /// The reference's priority colours: #ef4444, #fb923c, #60a5fa, #6b7280.
    static func priority(_ value: Int) -> Color {
        switch value {
        case 1: Color(red: 0.937, green: 0.267, blue: 0.267)
        case 2: Color(red: 0.984, green: 0.573, blue: 0.235)
        case 3: Color(red: 0.376, green: 0.647, blue: 0.98)
        default: Color(red: 0.42, green: 0.447, blue: 0.502)
        }
    }

    /// The reference's status tints (text over a tinted pill).
    static func status(_ status: TaskStatus) -> Color {
        switch status {
        case .inbox: Color(red: 0.82, green: 0.84, blue: 0.86)
        case .active: Color(red: 0.49, green: 0.83, blue: 0.99)
        case .done: Color(red: 0.43, green: 0.90, blue: 0.72)
        case .cancelled: Color(red: 0.99, green: 0.65, blue: 0.65)
        }
    }
    static let selection = WorkspaceStyle.accent
    static let overdue = Color(red: 0.937, green: 0.267, blue: 0.267)
    static let flow = Color(red: 0.957, green: 0.447, blue: 0.714)  // #f472b6
    static let persona = Color(red: 0.506, green: 0.549, blue: 0.973)  // #818cf8
    static let tag = Color(red: 0.22, green: 0.741, blue: 0.973)  // #38bdf8
    static let due = Color(red: 0.753, green: 0.518, blue: 0.988)  // #c084fc

    static func color(_ hex: String?) -> Color {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return flow }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static func priorityTitle(_ value: Int) -> String {
        switch value {
        case 1: "срочно"
        case 2: "высокий"
        case 3: "обычный"
        default: "без приоритета"
        }
    }
    static func statusTitle(_ status: TaskStatus) -> String { TaskStyleText.status(status) }
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
