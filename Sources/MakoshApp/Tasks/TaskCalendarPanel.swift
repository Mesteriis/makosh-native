import MakoshTasks
import SwiftUI

/// The month grid: dots on days with due tasks, the agenda's range, the
/// selected day; a click filters the list by that day.
struct TaskCalendarPanel: View {
    @ObservedObject var model: TasksWorkspaceModel

    private var today: Date { model.calendar.startOfDay(for: Date()) }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    model.calendarMonth = model.calendarMonth.previous()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless).accessibilityIdentifier("tasks.calendar.previous")
                Spacer()
                Button(model.calendarMonth.title) {
                    model.calendarMonth = TaskCalendarMonth.containing(
                        Date(), firstWeekday: model.calendarMonth.firstWeekday, calendar: model.calendar)
                }.buttonStyle(.plain).font(.caption.bold())
                Spacer()
                Button {
                    model.calendarMonth = model.calendarMonth.next()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless).accessibilityIdentifier("tasks.calendar.next")
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(model.calendarMonth.weekdayTitles, id: \.self) { title in
                    Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
                }
                ForEach(Array(model.calendarMonth.cells.enumerated()), id: \.offset) { _, cell in
                    if let day = cell { dayCell(day) } else { Color.clear.frame(height: 26) }
                }
            }
            if let day = model.filters.day {
                Button("Сбросить × " + model.storedPreferences.dateFormat.string(day, calendar: model.calendar)) { model.selectDay(nil) }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("tasks.calendar.clear")
            }
        }
        .padding(10)
        .accessibilityIdentifier("tasks.calendar")
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = model.calendar.isDate(day, inSameDayAs: today)
        let isSelected = model.filters.day.map { model.calendar.isDate($0, inSameDayAs: day) } ?? false
        let inRange = model.agendaRange.map { $0.contains(model.calendar.startOfDay(for: day)) } ?? false
        let hasTasks = model.dueDays.contains(model.calendar.startOfDay(for: day))
        return Button {
            model.selectDay(day)
        } label: {
            ZStack(alignment: .bottom) {
                Text(String(model.calendar.component(.day, from: day))).font(.caption).monospacedDigit()
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(
                        isSelected
                            ? TaskStyle.selection
                            : isToday ? Color.white.opacity(0.12) : inRange ? TaskStyle.selection.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .foregroundStyle(
                        isSelected ? Color.white : isToday ? TaskStyle.selection : inRange ? TaskStyle.selection : Color.secondary)
                if hasTasks {
                    Circle().fill(isSelected ? Color.white.opacity(0.7) : TaskStyle.due).frame(width: 4, height: 4).padding(.bottom, 2)
                }
            }
        }.buttonStyle(.plain).accessibilityIdentifier("tasks.calendar.day.\(model.calendar.component(.day, from: day))")
    }
}

/// The details panel: empty, several selected, or one task's rows.
struct TaskDetailsPanel: View {
    @ObservedObject var model: TasksWorkspaceModel
    let onEdit: (UUID) -> Void

    var body: some View {
        if let selected = model.selected, let task = model.task(id: selected) {
            TaskDetailView(model: model, task: task, onEdit: onEdit)
        } else if model.selection.selected.count > 1 {
            ScrollView {
                VStack(spacing: 10) {
                    Text(String(model.selection.selected.count)).font(.system(size: 40, weight: .bold)).foregroundStyle(TaskStyle.selection)
                    Text("задач выбрано").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(model.visible.filter { model.selection.selected.contains($0.id) }) { task in
                        HStack(spacing: 6) {
                            Image(systemName: statusSymbol(task.status)).font(.caption2).foregroundStyle(.secondary)
                            Text(task.title).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4).background(
                            Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    }
                }.padding(16)
            }.accessibilityIdentifier("tasks.details.multi")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 32)).foregroundStyle(.quaternary)
                Text("Выберите задачу,\nчтобы увидеть детали").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("tasks.details.empty")
        }
    }

    private func statusSymbol(_ status: TaskStatus) -> String {
        switch status {
        case .inbox: "tray"
        case .active: "bolt"
        case .done: "checkmark"
        case .cancelled: "xmark"
        }
    }
}
