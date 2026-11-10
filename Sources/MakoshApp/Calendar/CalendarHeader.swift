import MakoshCalendar
import SwiftUI

/// Section header: today, period navigation, view mode, summary or calendar, refresh, conflicts, task column.
struct CalendarHeader: View {
    @ObservedObject var model: CalendarWorkspaceModel
    @Binding var showTasks: Bool
    var newEvent: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Сегодня") {
                model.today()
                refresh()
            }.accessibilityIdentifier("calendar.header.today")
            Button {
                model.go(-1)
                refresh()
            } label: {
                Image(systemName: "chevron.left")
            }.buttonStyle(.borderless)
                .help("Назад (←)").accessibilityIdentifier("calendar.header.back")
            Button {
                model.go(1)
                refresh()
            } label: {
                Image(systemName: "chevron.right")
            }.buttonStyle(.borderless)
                .help("Вперёд (→)").accessibilityIdentifier("calendar.header.forward")
            Text(title).font(.title3.weight(.semibold)).lineLimit(1)
            Spacer()
            WorkspaceSegmentedPicker(
                "",
                selection: Binding(
                    get: { model.period.mode },
                    set: {
                        model.setMode($0)
                        refresh()
                    })
            ) {
                Text("День").tag(CalendarViewMode.day)
                Text("Неделя").tag(CalendarViewMode.week)
                Text("Месяц").tag(CalendarViewMode.month)
            }.labelsHidden().frame(width: 210).accessibilityIdentifier("calendar.header.mode")
            Menu {
                Button("Сводный вид") { model.select(collectionID: nil) }
                Divider()
                ForEach(model.snapshot?.collections ?? []) { collection in
                    Button(collection.name) { model.select(collectionID: collection.id) }
                }
            } label: {
                Label(model.selectedCollectionID.flatMap { model.collection($0)?.name } ?? "Сводный", systemImage: "square.stack.3d.up")
            }.fixedSize().accessibilityIdentifier("calendar.header.scope")
            if let conflicts = model.snapshot?.externalConflicts, !conflicts.isEmpty {
                Label("\(conflicts.count)", systemImage: "exclamationmark.2").foregroundStyle(.orange)
                    .help("Пересечения, появившиеся извне: события на одно время в календарях одной группы")
                    .accessibilityIdentifier("calendar.header.conflicts")
            }
            Button {
                _Concurrency.Task { await model.syncNow() }
            } label: {
                Image(systemName: model.syncing ? "arrow.triangle.2.circlepath.circle" : "arrow.clockwise")
            }.buttonStyle(.borderless).help("Обновить").disabled(model.syncing).accessibilityIdentifier("calendar.header.refresh")
            Button(action: newEvent) { Image(systemName: "plus") }.buttonStyle(.borderless).help("Новое событие (⌘N)")
                .keyboardShortcut("n", modifiers: .command).accessibilityIdentifier("calendar.header.new")
            Button {
                showTasks.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }.buttonStyle(.borderless)
                .foregroundStyle(showTasks ? WorkspaceStyle.accent : .secondary).help(showTasks ? "Скрыть задачи" : "Показать задачи")
                .accessibilityIdentifier("calendar.header.tasks")
        }
        .padding(.horizontal, 16).frame(height: CalendarStyle.headerHeight)
    }

    private var title: String {
        let span = model.period.interval(calendar: model.calendar)
        switch model.period.mode {
        case .day: return DateFormatter.calendar("EEEEdMMMMyyyy").string(from: model.period.anchor).capitalized
        case .month: return DateFormatter.calendar("LLLLyyyy").string(from: model.period.anchor).capitalized
        case .week:
            let end = span.end.addingTimeInterval(-1)
            return DateFormatter.calendar("dMMM").string(from: span.start) + " – " + DateFormatter.calendar("dMMMMyyyy").string(from: end)
        }
    }

    private func refresh() { _Concurrency.Task { await model.refresh() } }
}
