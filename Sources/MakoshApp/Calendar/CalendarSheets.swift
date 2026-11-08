import MakoshCalendar
import SwiftUI

/// The conflict question before a write: the overlaps and the four answers.
struct CalendarConflictSheet: View {
    @ObservedObject var model: CalendarWorkspaceModel
    let prompt: CalendarConflictPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Время пересекается", systemImage: "exclamationmark.triangle").font(.title2.bold())
            Text("В календарях этой группы на это время уже есть:").foregroundStyle(.secondary)
            ForEach(prompt.conflicts) { conflict in
                let event = model.event(conflict.eventID)
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(CalendarStyle.color(model.collection(conflict.collectionID)?.color ?? "")).frame(width: 9, height: 9)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conflict.isBusyCopy ? "Занято" : event?.title ?? "Событие").font(.headline)
                        Text(
                            [
                                model.collection(conflict.collectionID)?.name,
                                DateFormatter.calendar("dMMMHm").string(from: conflict.start) + "–"
                                    + DateFormatter.calendar("Hm").string(from: conflict.end),
                                event?.organizerEmail.map { "организатор " + $0 },
                            ]
                            .compactMap { $0 }.joined(separator: " · ")
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if event?.organizerEmail != nil {
                        Button("Написать организатору") { _Concurrency.Task { await model.resolveConflict(.writeToOrganizer(conflict)) } }
                            .accessibilityIdentifier("calendar.conflict.mail")
                    }
                    if conflict.isInvitation {
                        Button("Не приду") { _Concurrency.Task { await model.resolveConflict(.decline(conflict)) } }
                            .accessibilityIdentifier("calendar.conflict.decline")
                    }
                }
            }
            Divider()
            HStack {
                Button("Отмена") { model.conflict = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                if let suggestion = prompt.suggestion {
                    Button("Другое время: " + DateFormatter.calendar("EEdMMMHm").string(from: suggestion)) {
                        _Concurrency.Task { await model.resolveConflict(.pickTime(suggestion)) }
                    }.accessibilityIdentifier("calendar.conflict.pick")
                }
                Button("Всё равно записать") { _Concurrency.Task { await model.resolveConflict(.writeAnyway) } }
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("calendar.conflict.anyway")
            }
        }.padding(20).frame(width: 560)
    }
}

/// What a group change would write before it writes anything.
struct CalendarGroupPreviewSheet: View {
    @ObservedObject var model: CalendarWorkspaceModel
    let preview: BusyPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Изменение групп занятости", systemImage: "link").font(.title2.bold())
            if preview.create.isEmpty && preview.remove.isEmpty {
                Text("Плашки «Занято» не изменятся.").foregroundStyle(.secondary)
            }
            ForEach(Array(Set(preview.create.keys).union(preview.remove.keys)), id: \.self) { id in
                HStack {
                    Text(model.collection(id)?.name ?? "Календарь")
                    Spacer()
                    if let count = preview.create[id] { Text("поставить \(count)").foregroundStyle(.green) }
                    if let count = preview.remove[id] { Text("убрать \(count)").foregroundStyle(.orange) }
                }
            }
            Text("Плашки появятся у коллег во внешних календарях: только «Занято» и время, без названия и подробностей.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена") { model.cancelGroupChange() }.keyboardShortcut(.cancelAction)
                Button("Применить") { _Concurrency.Task { await model.confirmGroupChange() } }.keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("calendar.groups.apply")
            }
        }.padding(20).frame(width: 480)
    }
}
