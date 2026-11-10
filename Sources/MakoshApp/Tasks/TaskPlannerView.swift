import MakoshTasks
import SwiftUI

/// The day planner: week tabs, an hour grid, slots dropped from the list,
/// moved and resized by hand, blocked time, and the «now» line.
struct TaskPlannerView: View {
    @ObservedObject var model: TasksWorkspaceModel
    @State private var dragging: SlotDrag?
    @State private var resizing: SlotResize?
    @State private var editingBlocked: TaskPlanSlot?
    @State private var now = Date()

    private static let hourHeight: CGFloat = 60
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    struct SlotDrag: Equatable {
        let id: UUID
        var previewStart: Int
        var outside: Bool
    }
    struct SlotResize: Equatable {
        let id: UUID
        var previewEnd: Int
    }

    private var hours: (start: Int, end: Int) { (model.storedPreferences.plannerDayStart, model.storedPreferences.plannerDayEnd) }
    private var step: Int { model.storedPreferences.plannerStep }
    private var totalHeight: CGFloat { CGFloat(hours.end - hours.start) * Self.hourHeight }
    private var today: Date { model.calendar.startOfDay(for: now) }
    private var isToday: Bool { model.calendar.isDate(model.plannerDay, inSameDayAs: today) }

    var body: some View {
        VStack(spacing: 0) {
            weekTabs
            Divider()
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourLines
                    nowLine
                    ForEach(model.slots) { slot in slotView(slot) }
                    if model.slots.isEmpty {
                        Text("Перетащите задачи сюда или дважды кликните по времени").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, totalHeight / 2 - 10).allowsHitTesting(false)
                    }
                }
                .frame(height: totalHeight + 24).padding(.top, 8)
                .contentShape(Rectangle())
                .dropDestination(for: TaskDragPayload.self) { payloads, location in
                    let minutes = snapped(minutes(at: location.y - 8))
                    let ids = payloads.flatMap(\.ids)
                    _Concurrency.Task { await model.dropTasks(ids, at: minutes) }
                    return !ids.isEmpty
                }
                .gesture(emptyDoubleClick)
                .contextMenu { emptyMenu }
            }
        }
        .background { WorkspaceBackdrop(intensity: 0.5) }
        .onReceive(timer) { now = $0 }
        .sheet(item: $editingBlocked) { slot in BlockedSlotEditor(model: model, slot: slot).makoshAppearance() }
        .accessibilityIdentifier("tasks.planner")
    }

    // MARK: Week tabs

    private var weekTabs: some View {
        let days = TaskPlannerRules.weekDays(containing: model.plannerDay, calendar: model.calendar)
        let names = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
        return HStack(spacing: 2) {
            Button {
                shiftWeek(-7, from: days)
            } label: {
                Image(systemName: "chevron.left")
            }.buttonStyle(.borderless)
            Spacer()
            ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                let selected = model.calendar.isDate(day, inSameDayAs: model.plannerDay)
                let current = model.calendar.isDate(day, inSameDayAs: today)
                Button {
                    model.plannerDay = day
                } label: {
                    VStack(spacing: 1) {
                        Text(names[index]).font(.caption2.weight(.medium))
                        Text(String(model.calendar.component(.day, from: day))).font(.caption).underline(
                            current && !selected, color: TaskStyle.selection)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(selected ? TaskStyle.selection.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(selected || current ? TaskStyle.selection : .secondary)
                }.buttonStyle(.plain).accessibilityIdentifier("tasks.planner.day.\(index)")
            }
            Spacer()
            if !days.contains(where: { model.calendar.isDate($0, inSameDayAs: today) }) {
                Button("Сегодня") { model.plannerDay = today }.buttonStyle(.plain).font(.caption2).padding(.horizontal, 6).padding(
                    .vertical, 2
                )
                .background(TaskStyle.selection.opacity(0.2), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(TaskStyle.selection)
            }
            Button {
                shiftWeek(7, from: days)
            } label: {
                Image(systemName: "chevron.right")
            }.buttonStyle(.borderless)
        }.padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func shiftWeek(_ days: Int, from week: [Date]) {
        guard let anchor = days < 0 ? week.first : week.last, let target = model.calendar.date(byAdding: .day, value: days, to: anchor)
        else { return }
        model.plannerDay = target
    }

    // MARK: Grid

    private var hourLines: some View {
        ForEach(hours.start...hours.end, id: \.self) { hour in
            HStack(alignment: .top, spacing: 4) {
                Text(String(format: "%02d:00", hour)).font(.system(size: 10)).foregroundStyle(.secondary).frame(
                    width: 40, alignment: .trailing
                )
                .offset(y: -6)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
            .offset(y: CGFloat(hour - hours.start) * Self.hourHeight)
        }
    }

    @ViewBuilder private var nowLine: some View {
        let minutes = model.calendar.component(.hour, from: now) * 60 + model.calendar.component(.minute, from: now)
        if isToday, minutes >= hours.start * 60, minutes <= hours.end * 60 {
            HStack(spacing: 0) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Rectangle().fill(Color.red).frame(height: 2)
            }
            .padding(.leading, 40).offset(y: y(for: minutes) - 4).allowsHitTesting(false).zIndex(5)
        }
    }

    private func y(for minutes: Int) -> CGFloat { CGFloat(minutes - hours.start * 60) / 60 * Self.hourHeight }
    private func minutes(at y: CGFloat) -> Int { hours.start * 60 + Int(y / Self.hourHeight * 60) }
    private func snapped(_ minutes: Int) -> Int {
        max(hours.start * 60, min((minutes / step) * step, hours.end * 60 - step))
    }

    private var emptyDoubleClick: some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in
            guard !model.slots.contains(where: { slotRect($0).contains(value.location) }) else { return }
            model.createTaskHere(at: snapped(minutes(at: value.location.y - 8)))
            model.toast("Создайте задачу в строке ввода — она встанет на \(TaskPlanSlot.time(snapped(minutes(at: value.location.y - 8))))")
        }
    }

    @ViewBuilder private var emptyMenu: some View {
        Button("Занять время с начала дня") { _Concurrency.Task { await model.blockSlot(at: hours.start * 60) } }
        Button("Создать задачу с начала дня") { model.createTaskHere(at: hours.start * 60) }
    }

    private func slotRect(_ slot: TaskPlanSlot) -> CGRect {
        CGRect(x: 44, y: y(for: slot.start) + 8, width: 1000, height: CGFloat(slot.minutes) / 60 * Self.hourHeight)
    }

    // MARK: Slots

    private func slotView(_ slot: TaskPlanSlot) -> some View {
        let task = slot.taskID.flatMap { model.task(id: $0) }
        let start = dragging?.id == slot.id ? dragging!.previewStart : slot.start
        let end = resizing?.id == slot.id ? resizing!.previewEnd : start + slot.minutes
        let height = max(20, CGFloat(end - start) / 60 * Self.hourHeight)
        let color = task.map { TaskStyle.priority($0.priority) } ?? Color.gray
        let blocked = slot.kind == .blocked
        let done = task?.status == .done
        return SlotBody(
            slot: slot, task: task, start: start, end: end, height: height, color: color, blocked: blocked, done: done,
            dateFormat: model.storedPreferences.dateFormat, calendar: model.calendar
        )
        .frame(height: height)
        .padding(.leading, 44).padding(.trailing, 4)
        .offset(y: y(for: start))
        .opacity(dragging?.id == slot.id ? (dragging!.outside ? 0.2 : 0.7) : 1)
        .zIndex(dragging?.id == slot.id ? 10 : 1)
        .gesture(moveGesture(slot))
        .onTapGesture(count: 2) {
            if let task { model.selected = task.id } else if blocked { editingBlocked = slot }
        }
        .onTapGesture { if let task { model.selected = task.id } }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.clear).frame(height: 8).contentShape(Rectangle()).padding(.leading, 44).padding(.trailing, 4)
                .gesture(resizeGesture(slot))
                .onHover { inside in if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() } }
        }
        .contextMenu { slotMenu(slot, task: task) }
        .accessibilityIdentifier("tasks.planner.slot.\(slot.id.uuidString)")
    }

    private func moveGesture(_ slot: TaskPlanSlot) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                let delta = Int(value.translation.height / Self.hourHeight * 60)
                let raw = TaskPlannerRules.snap(slot.start + delta, step: step)
                let clamped = max(hours.start * 60, min(raw, hours.end * 60 - slot.minutes))
                let outside = abs(value.translation.width) > 160
                dragging = SlotDrag(id: slot.id, previewStart: clamped, outside: outside)
            }
            .onEnded { value in
                defer { dragging = nil }
                if abs(value.translation.width) > 160 {
                    _Concurrency.Task { await model.removeSlot(id: slot.id) }
                } else if let preview = dragging?.previewStart, preview != slot.start {
                    _Concurrency.Task { await model.moveSlot(id: slot.id, to: preview) }
                }
            }
    }

    private func resizeGesture(_ slot: TaskPlanSlot) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                let delta = Int(value.translation.height / Self.hourHeight * 60)
                let raw = TaskPlannerRules.snap(slot.end + delta, step: step)
                resizing = SlotResize(id: slot.id, previewEnd: max(slot.start + step, min(raw, hours.end * 60)))
            }
            .onEnded { _ in
                defer { resizing = nil }
                if let preview = resizing?.previewEnd, preview != slot.end {
                    _Concurrency.Task { await model.resizeSlot(id: slot.id, end: preview) }
                }
            }
    }

    @ViewBuilder private func slotMenu(_ slot: TaskPlanSlot, task: Task?) -> some View {
        if let task {
            Button(task.status == .done ? "Вернуть" : "Выполнить") { _Concurrency.Task { await model.bulkToggleDone(ids: [task.id]) } }
            Button("Изменить задачу") { model.selected = task.id }
            Divider()
        }
        if slot.kind == .blocked {
            Button("Изменить") { editingBlocked = slot }
            Menu("Повтор") {
                Button("Нет") { _Concurrency.Task { await model.updateSlot(id: slot.id, title: slot.title, recurrence: nil) } }
                Button("Ежедневно") { _Concurrency.Task { await model.updateSlot(id: slot.id, title: slot.title, recurrence: .daily) } }
                Button("Еженедельно") { _Concurrency.Task { await model.updateSlot(id: slot.id, title: slot.title, recurrence: .weekly) } }
                Button("Раз в две недели") {
                    _Concurrency.Task { await model.updateSlot(id: slot.id, title: slot.title, recurrence: .biweekly) }
                }
            }
            Button("Освободить") { _Concurrency.Task { await model.unblockSlot(id: slot.id) } }
            Divider()
        }
        Button("Занять время после") { _Concurrency.Task { await model.blockSlot(at: slot.end) } }
        Button("Создать задачу после") { model.createTaskHere(at: slot.end) }
        Divider()
        Button("Убрать из плана", role: .destructive) { _Concurrency.Task { await model.removeSlot(id: slot.id) } }
    }
}

/// One slot's face: compact in one line under 36 pt, otherwise title, list and tags, then the times.
private struct SlotBody: View {
    let slot: TaskPlanSlot
    let task: Task?
    let start: Int
    let end: Int
    let height: CGFloat
    let color: Color
    let blocked: Bool
    let done: Bool
    let dateFormat: TaskDateFormat
    let calendar: Calendar

    private var title: String { blocked ? (slot.title ?? "Занято") : (task?.title ?? "—") }

    var body: some View {
        HStack(spacing: 0) {
            if !blocked { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3) }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if done { Image(systemName: "checkmark").font(.system(size: 9)).foregroundStyle(.green) }
                    if blocked { Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(.secondary) }
                    ForEach(task?.personas ?? [], id: \.self) { persona in
                        Text(persona).font(.system(size: 9)).padding(.horizontal, 3).background(
                            TaskStyle.persona.opacity(0.15), in: RoundedRectangle(cornerRadius: 3)
                        ).foregroundStyle(TaskStyle.persona)
                    }
                    Text(title).font(.caption.weight(.medium)).strikethrough(done).foregroundStyle(done || blocked ? .secondary : .primary)
                        .lineLimit(1)
                    if height < 50, let task { meta(task) }
                    Spacer(minLength: 0)
                    if blocked, slot.recurrence != nil { Image(systemName: "repeat").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if height < 36 { times }
                }
                if height >= 50, let task { HStack(spacing: 4) { meta(task) } }
                if height >= 36 {
                    Spacer(minLength: 0)
                    times
                }
            }.padding(.horizontal, 6).padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(blocked ? Color.gray.opacity(0.12) : color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(
                blocked ? Color.gray.opacity(0.4) : color, style: StrokeStyle(lineWidth: 1, dash: blocked ? [4, 3] : []))
        )
        .opacity(done ? 0.5 : 1)
    }

    @ViewBuilder private func meta(_ task: Task) -> some View {
        if let list = task.list { Text("@" + list).font(.system(size: 9)).foregroundStyle(TaskStyle.tag.opacity(0.7)).lineLimit(1) }
        ForEach(task.tags.prefix(2), id: \.self) { tag in Text("#" + tag).font(.system(size: 9)).foregroundStyle(TaskStyle.tag.opacity(0.5))
        }
    }

    private var times: some View {
        Text("\(TaskPlanSlot.time(start))–\(TaskPlanSlot.time(end))").font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
    }
}

/// The blocked slot's title and recurrence.
struct BlockedSlotEditor: View {
    @ObservedObject var model: TasksWorkspaceModel
    let slot: TaskPlanSlot
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var recurrence: TaskPlanSlot.Recurrence?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Занятое время").font(.headline)
            TextField("Занято", text: $title).textFieldStyle(WorkspaceTextFieldStyle()).accessibilityIdentifier(
                "tasks.planner.blocked.title")
            Text("Повтор").font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                option(nil, "Нет")
                option(.daily, "Ежедневно")
                option(.weekly, "Еженедельно")
                option(.biweekly, "Раз в две недели")
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    let value = (title, recurrence)
                    dismiss()
                    _Concurrency.Task { await model.updateSlot(id: slot.id, title: value.0, recurrence: value.1) }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 380)
        .onAppear {
            title = slot.title ?? ""
            recurrence = slot.recurrence
        }
    }

    private func option(_ value: TaskPlanSlot.Recurrence?, _ label: String) -> some View {
        Button(label) { recurrence = value }.buttonStyle(.plain).font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(recurrence == value ? TaskStyle.selection.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(recurrence == value ? TaskStyle.selection : Color.white.opacity(0.15)))
            .foregroundStyle(recurrence == value ? TaskStyle.selection : .secondary)
    }
}
