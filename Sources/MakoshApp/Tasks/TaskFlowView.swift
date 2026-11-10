import MakoshTasks
import SwiftUI

/// The pinned flow under the list: its card, progress, and the dependency
/// graph with arrows from blocker to blocked; a drag from a node's right
/// handle to another's left handle adds a dependency.
struct TaskFlowView: View {
    @ObservedObject var model: TasksWorkspaceModel
    let flow: String
    let onEdit: (UUID) -> Void
    @State private var editingMeta = false
    @State private var description = ""
    @State private var color = ""
    @State private var deadline = ""
    @State private var connecting: (from: UUID, point: CGPoint)?
    @State private var confirmDelete = false

    private static let nodeSize = CGSize(width: 200, height: 76)
    private static let gap = CGSize(width: 80, height: 20)

    private var tasks: [Task] { model.flowTasks }
    private var meta: TaskFlow? { model.flowMeta[flow] }
    private var tint: Color { TaskStyle.color(meta?.color) }
    private var layout: TaskFlowLayout { TaskFlowLayout.make(tasks, nodeSize: Self.nodeSize, gap: Self.gap) }
    private var nextReady: Task? { TaskFlowRules.nextReady(tasks, resolve: { model.task(id: $0) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if editingMeta { metaEditor } else if meta?.description.isEmpty == false || meta?.deadline != nil { metaInfo }
            progress
            if !tasks.isEmpty { canvas }
        }
        .padding(14)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
        .padding(.horizontal, 12).padding(.bottom, 12)
        .alert("Удалить цепочку «\(flow)»?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { _Concurrency.Task { await model.deleteFlow(name: flow) } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Задачи останутся, у них исчезнет имя цепочки.")
        }
        .accessibilityIdentifier("tasks.flow.\(flow)")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt").foregroundStyle(tint)
            Text("Цепочка: \(flow)").font(.callout.weight(.semibold)).foregroundStyle(tint)
            Spacer()
            if let next = nextReady {
                Button {
                    _Concurrency.Task { await model.startNext(inFlow: flow) }
                } label: {
                    Label("Запустить следующую", systemImage: "play.fill").font(.caption)
                }
                .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.orange)
                .help(next.title).accessibilityIdentifier("tasks.flow.startNext")
            }
            Button {
                description = meta?.description ?? ""
                color = meta?.color ?? ""
                deadline = meta?.deadline.map { TaskDateFormat.dmy.string($0, calendar: model.calendar) } ?? ""
                editingMeta.toggle()
            } label: {
                Image(systemName: "pencil")
            }.buttonStyle(.borderless).help("Описание, срок, цвет").accessibilityIdentifier("tasks.flow.edit")
            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }.buttonStyle(.borderless).foregroundStyle(.red.opacity(0.7))
                .help("Удалить цепочку").accessibilityIdentifier("tasks.flow.delete")
        }
    }

    private var metaInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let text = meta?.description, !text.isEmpty { Text(text).font(.caption).foregroundStyle(.secondary) }
            if let deadline = meta?.deadline {
                Label("Срок: " + model.storedPreferences.dateFormat.string(deadline, calendar: model.calendar), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(TaskStyle.due)
            }
        }
    }

    private var metaEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Описание", text: $description).textFieldStyle(WorkspaceTextFieldStyle())
            TaskDateField(text: $deadline, calendar: model.calendar)
            HStack(spacing: 6) {
                ForEach(TaskFlow.palette, id: \.self) { option in
                    Button {
                        color = option
                    } label: {
                        Circle().fill(option.isEmpty ? Color.white.opacity(0.15) : TaskStyle.color(option)).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.white, lineWidth: color == option ? 2 : 0))
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Button("OK") {
                    let value = TaskFlow(
                        name: flow, description: description.trimmingCharacters(in: .whitespaces), color: color.isEmpty ? nil : color,
                        deadline: deadline.isEmpty ? nil : TaskFieldInput.date(deadline, today: Date(), calendar: model.calendar))
                    editingMeta = false
                    _Concurrency.Task { await model.saveFlow(value) }
                }.controlSize(.small)
                Button("Отмена") { editingMeta = false }.controlSize(.small)
            }
        }
        .padding(10).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var progress: some View {
        let value = model.flowProgress(flow)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Прогресс").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(value.done)/\(value.total) (\(value.percent) %)").font(.caption2).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(tint).frame(width: geometry.size.width * CGFloat(value.percent) / 100)
                }
            }.frame(height: 5)
        }
    }

    private var canvas: some View {
        let layout = layout
        let positions = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
        return ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in layout.edges {
                        guard let from = positions[edge.from], let to = positions[edge.to] else { continue }
                        let start = CGPoint(x: from.x + Self.nodeSize.width, y: from.y + Self.nodeSize.height / 2)
                        let end = CGPoint(x: to.x, y: to.y + Self.nodeSize.height / 2)
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(
                            to: end, control1: CGPoint(x: start.x + Self.gap.width / 2, y: start.y),
                            control2: CGPoint(x: end.x - Self.gap.width / 2, y: end.y))
                        context.stroke(path, with: .color(.gray), lineWidth: 1.5)
                        var head = Path()
                        head.move(to: end)
                        head.addLine(to: CGPoint(x: end.x - 8, y: end.y - 4))
                        head.addLine(to: CGPoint(x: end.x - 8, y: end.y + 4))
                        head.closeSubpath()
                        context.fill(head, with: .color(.gray))
                    }
                    if let connecting, let from = positions[connecting.from] {
                        var path = Path()
                        path.move(to: CGPoint(x: from.x + Self.nodeSize.width, y: from.y + Self.nodeSize.height / 2))
                        path.addLine(to: connecting.point)
                        context.stroke(path, with: .color(TaskStyle.selection), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                ForEach(tasks) { task in
                    if let position = positions[task.id] { node(task).offset(x: position.x, y: position.y) }
                }
            }
            .frame(width: max(layout.size.width, 200), height: max(layout.size.height, Self.nodeSize.height))
            .padding(8)
            .coordinateSpace(name: "flowCanvas")
        }
        .frame(maxHeight: min(max(layout.size.height + 24, 100), 320))
        .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }

    private func node(_ task: Task) -> some View {
        let blocked = task.status != .done && model.isBlocked(task)
        let ready = TaskFlowRules.isReady(task, resolve: { model.task(id: $0) })
        let stroke: Color = ready ? .orange : blocked ? .gray : TaskStyle.status(task.status)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                if blocked { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(.yellow.opacity(0.7)) }
                TaskPriorityBadge(priority: task.priority)
                Text(task.title).font(.system(size: 11)).lineLimit(2).strikethrough(task.status == .done)
                    .foregroundStyle(task.status == .done || blocked ? .secondary : .primary)
            }
            HStack(spacing: 4) {
                Text(TaskStyleText.status(task.status)).font(.system(size: 9)).foregroundStyle(.secondary)
                if ready { Text("— готова к запуску").font(.system(size: 9, weight: .medium)).foregroundStyle(.orange) }
            }
        }
        .padding(8).frame(width: Self.nodeSize.width, height: Self.nodeSize.height, alignment: .topLeading)
        .background((ready ? Color.orange : stroke).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(stroke.opacity(ready ? 1 : 0.6)))
        .opacity(blocked ? 0.7 : 1)
        .overlay(alignment: .leading) { handle(task, target: true) }
        .overlay(alignment: .trailing) { handle(task, target: false) }
        .onTapGesture(count: 2) { onEdit(task.id) }
        .onTapGesture { model.selected = task.id }
        .contextMenu { nodeMenu(task, blocked: blocked, ready: ready) }
        .accessibilityIdentifier("tasks.flow.node.\(task.code)")
    }

    /// The left handle receives a connection, the right one starts it.
    private func handle(_ task: Task, target: Bool) -> some View {
        Circle().fill(Color(white: 0.35)).frame(width: 10, height: 10).overlay(Circle().stroke(Color(white: 0.6)))
            .offset(x: target ? -5 : 5)
            .contentShape(Circle().scale(2))
            .gesture(
                target
                    ? nil
                    : DragGesture(minimumDistance: 2, coordinateSpace: .named("flowCanvas"))
                        .onChanged { value in connecting = (task.id, value.location) }
                        .onEnded { value in
                            defer { connecting = nil }
                            let positions = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
                            guard
                                let hit = positions.first(where: { id, point in
                                    id != task.id
                                        && CGRect(origin: point, size: Self.nodeSize).insetBy(dx: -12, dy: -12).contains(value.location)
                                })
                            else { return }
                            _Concurrency.Task { await model.addDependency(id: hit.key, on: task.id) }
                        }
            )
    }

    @ViewBuilder private func nodeMenu(_ task: Task, blocked: Bool, ready: Bool) -> some View {
        if task.status == .done {
            Button("Вернуть") { _Concurrency.Task { await model.set(status: .active, id: task.id) } }
        } else if !blocked {
            Button("Выполнить") { _Concurrency.Task { await model.set(status: .done, id: task.id) } }
        }
        if ready { Button("Запустить") { _Concurrency.Task { await model.set(status: .active, id: task.id) } } }
        Button("Изменить") { onEdit(task.id) }
        Divider()
        ForEach(task.dependsOn, id: \.self) { dependency in
            Button("Убрать зависимость: " + String((model.task(id: dependency)?.title ?? "?").prefix(20))) {
                _Concurrency.Task { await model.removeDependency(id: task.id, on: dependency) }
            }
        }
        Button("Убрать из цепочки") { _Concurrency.Task { await model.setFlow(id: task.id, name: nil) } }
        Divider()
        Button("Удалить", role: .destructive) { _Concurrency.Task { await model.bulkDelete(ids: [task.id]) } }
    }
}
