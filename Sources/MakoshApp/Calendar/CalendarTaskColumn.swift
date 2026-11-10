import MakoshCalendar
import SwiftUI

/// Right column: tasks to drag onto the grid, where they become events of the default calendar.
struct CalendarTaskColumn: View {
    @ObservedObject var model: CalendarWorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Задачи").font(.headline)
                Spacer()
                MakoshPicker(
                    "",
                    selection: Binding(
                        get: { model.agenda },
                        set: {
                            model.agenda = $0
                            _Concurrency.Task { await model.refresh() }
                        })
                ) {
                    ForEach(CalendarTaskAgenda.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().fixedSize().accessibilityIdentifier("calendar.tasks.agenda")
            }
            if let id = model.defaultCollectionID, let collection = model.collection(id) {
                Label("В календарь «\(collection.name)»", systemImage: "arrow.down.to.line").font(.caption).foregroundStyle(.secondary)
            }
            if model.taskFeed == nil {
                Text("Раздел «Задачи» ещё не открыт.").font(.callout).foregroundStyle(.secondary)
            } else if model.tasks.isEmpty {
                Text("Нет задач в этой повестке.").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.tasks) { task in
                        HStack(spacing: 6) {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.title).lineLimit(2)
                                HStack(spacing: 6) {
                                    if let minutes = task.estimateMinutes { Text("\(minutes) мин") }
                                    if let due = task.due {
                                        Text(DateFormatter.calendar("dMMM").string(from: due)).foregroundStyle(
                                            task.overdue ? .red : .secondary)
                                    }
                                }.font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(7).background(WorkspaceStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                        .draggable(task.id.uuidString)
                        .help("Перетащите на сетку: задача станет событием")
                        .accessibilityIdentifier("calendar.tasks.row")
                    }
                }
            }
            Text("Задача ложится на ближайшее свободное время с учётом занятости групп.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).frame(width: CalendarStyle.taskColumnWidth)
    }
}
