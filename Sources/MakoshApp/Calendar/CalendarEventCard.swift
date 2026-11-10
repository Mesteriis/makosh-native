import AppKit
import MakoshCalendar
import SwiftUI

/// What the event sheet edits: a new event, or an existing one (with the occurrence clicked).
struct CalendarEventSheetRequest: Identifiable {
    let id = UUID()
    var eventID: UUID?
    var occurrenceKey: Date?
    var start: Date
    var end: Date
}

/// The event sheet: fields of the design, the meeting link, invitation answers and journaled attempts.
/// A busy copy shows only «Занято» and its source.
struct CalendarEventCard: View {
    @ObservedObject var model: CalendarWorkspaceModel
    @ObservedObject var host: CalendarHost
    let request: CalendarEventSheetRequest
    var close: () -> Void

    @State private var title = ""
    @State private var collectionID: UUID?
    @State private var allDay = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var repeatRule = ""
    @State private var location = ""
    @State private var notes = ""
    @State private var attendees = ""
    @State private var reminder = -1
    @State private var free = false
    @State private var meeting = ""
    @State private var askScope: (() -> Void)?
    @State private var scopeAction: ((CalendarEditScope) -> Void)?
    @State private var addingTelemost = false

    private var event: CalendarEvent? { request.eventID.flatMap(model.event) }
    private var isCopy: Bool { event?.isBusyCopy == true }
    private var account: CalendarAccount? {
        collectionID.flatMap(model.collection).flatMap { c in model.snapshot?.accounts.first { $0.id == c.accountID } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isCopy, let event { copyCard(event) } else { form }
        }
        .padding(20).frame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog(
            "Изменить повторяющееся событие", isPresented: Binding(get: { scopeAction != nil }, set: { if !$0 { scopeAction = nil } })
        ) {
            Button("Только это") {
                scopeAction?(.occurrence)
                scopeAction = nil
            }
            Button("Вся серия") {
                scopeAction?(.series)
                scopeAction = nil
            }
            Button("Отмена", role: .cancel) { scopeAction = nil }
        }
    }

    private func copyCard(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Занято", systemImage: "lock.rectangle").font(.title2.bold())
            let source = event.busyMarker.flatMap { model.event($0.sourceEventID) }
            Text(
                "Плашка поставлена Makosh по событию «\(source?.title ?? "—")» в календаре «\(source.flatMap { model.collection($0.collectionID) }?.name ?? "—")». Её меняет только исходное событие; правка прямо в календаре откатится при следующем обходе."
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if let source {
                    Button("Перейти к оригиналу") {
                        model.select(collectionID: nil)
                        host.openEventRequest = source.id
                    }
                }
                Button("Закрыть", action: close).keyboardShortcut(.cancelAction)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Название", text: $title).textFieldStyle(WorkspaceTextFieldStyle()).font(.title3).accessibilityIdentifier(
                "calendar.card.title")
            MakoshPicker("Календарь", selection: $collectionID) {
                ForEach(model.writableCollections) { collection in Text(collection.name).tag(Optional(collection.id)) }
            }.disabled(event != nil).accessibilityIdentifier("calendar.card.collection")
            Toggle("Весь день", isOn: $allDay)
            HStack {
                DatePicker("Начало", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("Конец", selection: $end, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
            }
            MakoshPicker("Повтор", selection: $repeatRule) {
                Text("Не повторять").tag("")
                Text("Каждый день").tag("FREQ=DAILY")
                Text("По будням").tag("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
                Text("Каждую неделю").tag("FREQ=WEEKLY")
                Text("Каждый месяц").tag("FREQ=MONTHLY")
                Text("Каждый год").tag("FREQ=YEARLY")
                if !["", "FREQ=DAILY", "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", "FREQ=WEEKLY", "FREQ=MONTHLY", "FREQ=YEARLY"].contains(
                    repeatRule)
                {
                    Text("Своё правило").tag(repeatRule)
                }
            }
            if !repeatRule.isEmpty, CalendarRecurrenceExpander.unsupported(rrule: repeatRule) {
                Text("Это правило повтора Makosh показывает только первым вхождением.").font(.caption).foregroundStyle(.orange)
            }
            TextField("Место", text: $location).textFieldStyle(WorkspaceTextFieldStyle())
            HStack {
                TextField("Ссылка на встречу", text: $meeting).textFieldStyle(WorkspaceTextFieldStyle())
                if let url = URL(string: meeting), url.scheme == "https" {
                    Button("Подключиться") { NSWorkspace.shared.open(url) }.accessibilityIdentifier("calendar.card.join")
                }
                if meeting.isEmpty, host.canAddTelemost(collectionID: collectionID) {
                    Button(addingTelemost ? "Создаю…" : "Добавить Telemost") {
                        addingTelemost = true
                        _Concurrency.Task {
                            if let url = await host.createTelemost(title: title) { meeting = url.absoluteString }
                            addingTelemost = false
                        }
                    }.disabled(addingTelemost).accessibilityIdentifier("calendar.card.telemost")
                }
            }
            if account?.kind != .local {
                TextField("Участники: адреса через запятую", text: $attendees).textFieldStyle(WorkspaceTextFieldStyle())
                    .accessibilityIdentifier("calendar.card.attendees")
                if !host.contactSuggestions(for: attendees).isEmpty {
                    HStack {
                        ForEach(host.contactSuggestions(for: attendees), id: \.self) { email in
                            Button(email) { attendees = Self.complete(attendees, with: email) }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
                if account?.kind == .caldav, account?.serverSchedules == false, !attendees.isEmpty {
                    Text("Сервер этого календаря не рассылает приглашения сам: участники сохранятся только в Makosh.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            MakoshPicker("Напоминание", selection: $reminder) {
                Text("По умолчанию календаря").tag(-1)
                ForEach([0, 5, 10, 15, 30, 60, 1440], id: \.self) { minutes in
                    Text(minutes == 0 ? "В момент начала" : minutes == 1440 ? "За день" : "За \(minutes) мин").tag(minutes)
                }
            }
            Toggle("Свободен (не давать «Занято»)", isOn: $free)
            TextEditor(text: $notes).workspaceEditorSurface().frame(height: 70)
            if let event, event.attendees.contains(where: \.isSelf) { responses(event) }
            if let event { attempts(event) }
            HStack {
                if event != nil {
                    Button("Удалить", role: .destructive) { remove() }.accessibilityIdentifier("calendar.card.delete")
                }
                Spacer()
                Button("Отмена", action: close).keyboardShortcut(.cancelAction)
                Button(event == nil ? "Создать" : "Сохранить") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(collectionID == nil).accessibilityIdentifier("calendar.card.save")
            }
        }
    }

    private func responses(_ event: CalendarEvent) -> some View {
        HStack {
            Text("Ваш ответ: " + Self.title(event.selfResponse)).foregroundStyle(.secondary)
            Spacer()
            ForEach([CalendarResponse.accepted, .tentative, .declined], id: \.self) { response in
                Button(response == .accepted ? "Приду" : response == .tentative ? "Возможно" : "Не приду") {
                    _Concurrency.Task {
                        await model.respond(eventID: event.id, response)
                        close()
                    }
                }.disabled(event.selfResponse == response)
            }
        }
    }

    @ViewBuilder private func attempts(_ event: CalendarEvent) -> some View {
        let open = model.snapshot?.openAttempts.filter { $0.eventID == event.id } ?? []
        ForEach(open) { attempt in
            HStack {
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
                Text(attempt.state == .unknown ? "Ответ сервера не получен — запись не повторяется сама." : "Запись отправляется…").font(
                    .caption)
                Spacer()
                Button("Проверить") { _Concurrency.Task { await model.check(attemptID: attempt.id) } }
                Button("Отказаться") { _Concurrency.Task { await model.dismiss(attemptID: attempt.id) } }
            }
        }
    }

    private func load() {
        collectionID = model.defaultCollectionID
        start = request.start
        end = request.end
        guard let event else { return }
        title = event.title
        collectionID = event.collectionID
        location = event.location
        notes = event.notes
        meeting = event.meetingURL?.absoluteString ?? ""
        attendees = event.attendees.filter { !$0.isSelf && !$0.isOrganizer }.map(\.email).joined(separator: ", ")
        reminder = event.reminders.first ?? -1
        free = event.transparency == .free
        repeatRule = (event.masterID.flatMap(model.event) ?? event).recurrence?.rrule ?? ""
        switch event.time {
        case .timed(let from, let to, _):
            allDay = false
            if request.occurrenceKey == nil {
                start = from
                end = to
            }
        case .allDay(let from, let to):
            allDay = true
            start = Self.date(from)
            end = Self.date(to).addingTimeInterval(-86400)
        }
    }

    private var draft: CalendarDraft? {
        guard let collectionID else { return nil }
        let time: CalendarEventTime
        if allDay {
            let calendar = Calendar.current
            let a = calendar.dateComponents([.year, .month, .day], from: start),
                b = calendar.dateComponents([.year, .month, .day], from: max(end, start))
            let last = CalendarDay(year: b.year!, month: b.month!, day: b.day!)
            time = .allDay(start: CalendarDay(year: a.year!, month: a.month!, day: a.day!), endExclusive: ICalendarDay.next(last))
        } else {
            time = .timed(start: start, end: max(end, start.addingTimeInterval(900)), timeZone: TimeZone.current.identifier)
        }
        let master = event.flatMap { $0.masterID.flatMap(model.event) ?? $0 }
        return CalendarDraft(
            collectionID: collectionID, title: title.trimmingCharacters(in: .whitespaces), notes: notes, location: location, time: time,
            recurrence: repeatRule.isEmpty ? nil : CalendarRecurrence(rrule: repeatRule, exdates: master?.recurrence?.exdates ?? []),
            attendees: attendees.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("@") },
            reminders: reminder < 0 ? [] : [reminder], meetingURL: URL(string: meeting).flatMap { $0.scheme == "https" ? $0 : nil },
            transparency: free ? .free : .busy, taskID: event?.taskID)
    }

    private func save() {
        guard let draft else { return }
        guard let event else {
            _Concurrency.Task {
                await model.create(draft)
                close()
            }
            return
        }
        let master = event.masterID.flatMap(model.event) ?? event
        let run: (CalendarEditScope) -> Void = { scope in
            _Concurrency.Task {
                await model.update(
                    eventID: master.id, occurrenceKey: request.occurrenceKey ?? event.recurrenceID, draft: draft, scope: scope)
                close()
            }
        }
        if master.recurrence != nil { scopeAction = run } else { run(.series) }
    }

    private func remove() {
        guard let event else { return }
        let master = event.masterID.flatMap(model.event) ?? event
        let run: (CalendarEditScope) -> Void = { scope in
            _Concurrency.Task {
                await model.delete(eventID: master.id, occurrenceKey: request.occurrenceKey ?? event.recurrenceID, scope: scope)
                close()
            }
        }
        if master.recurrence != nil { scopeAction = run } else { run(.series) }
    }

    static func complete(_ text: String, with email: String) -> String {
        var parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = parts.last, !last.contains("@") { parts.removeLast() }
        return (parts + [email]).joined(separator: ", ")
    }

    static func date(_ day: CalendarDay) -> Date {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
    }

    static func title(_ response: CalendarResponse?) -> String {
        switch response {
        case .accepted?: "приду"
        case .tentative?: "возможно"
        case .declined?: "не приду"
        default: "нет ответа"
        }
    }
}

enum ICalendarDay {
    static func next(_ day: CalendarDay) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!.addingTimeInterval(86400)
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return CalendarDay(year: c.year!, month: c.month!, day: c.day!)
    }
}
