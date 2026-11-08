import Foundation

/// The isolated QA world: a personal Google, two work calendars (Google and Yandex
/// CalDAV), a holiday feed and the local calendar, all synthetic, in one busy group.
public enum CalendarSyntheticSeed {
    public static let personal = "Личный Google"
    public static let workA = "Работа A"
    public static let workB = "Работа B (Яндекс)"
    public static let holidays = "Праздники"

    static func day(_ now: Date) -> Date { Calendar.current.startOfDay(for: now) }

    /// Synthetic servers by account name, with events around `now`.
    public static func adapters(now: Date) -> [String: CalendarSyntheticAdapter] {
        let base = day(now)
        func at(_ day: Int, _ hour: Double) -> Date { base.addingTimeInterval(Double(day) * 86400 + hour * 3600) }
        func event(_ title: String, _ day: Int, _ from: Double, _ to: Double) -> CalendarEvent {
            CalendarEvent(
                collectionID: UUID(), uid: "qa-\(title.hashValue.magnitude)-\(day)@synthetic", title: title,
                time: .timed(start: at(day, from), end: at(day, to), timeZone: nil))
        }
        var dentist = event("Стоматолог", 1, 14, 15)
        dentist.uid = "qa-dentist@synthetic"
        dentist.notes = "Клиника, кабинет 4"
        dentist.location = "ул. Пушкина, 10"
        var call = event("Созвон A", 1, 10, 11)
        call.uid = "qa-call-a@synthetic"
        var standup = event("Планёрка", 0, 9.5, 9.75)
        standup.uid = "qa-standup@synthetic"
        standup.recurrence = CalendarRecurrence(rrule: "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR")
        var invite = event("Совещание с заказчиком", 2, 12, 13)
        invite.uid = "qa-invite@synthetic"
        invite.organizerEmail = "boss@client-a.test"
        invite.attendees = [
            CalendarAttendee(email: "boss@client-a.test", name: "Руководитель", response: .accepted, isOrganizer: true),
            CalendarAttendee(email: "me@work-a.test", response: .needsAction, isSelf: true),
        ]
        var overlap = event("Внешний созвон", 1, 14.5, 15.5)
        overlap.uid = "qa-overlap@synthetic"
        var telemost = event("Telemost · B", 1, 16, 17)
        telemost.uid = "qa-telemost@synthetic"
        telemost.meetingURL = URL(string: "https://telemost.yandex.ru/j/12345678901234")
        telemost.location = "https://telemost.yandex.ru/j/12345678901234"
        let c = Calendar.current.dateComponents([.year, .month, .day], from: at(3, 0))
        let holiday = CalendarEvent(
            collectionID: UUID(), uid: "qa-holiday@synthetic", title: "Праздничный день",
            time: .allDay(
                start: CalendarDay(year: c.year!, month: c.month!, day: c.day!),
                endExclusive: ICalendar.adding(days: 1, to: CalendarDay(year: c.year!, month: c.month!, day: c.day!))),
            transparency: .free)
        return [
            personal: CalendarSyntheticAdapter(
                collections: [RemoteCollection(externalID: "personal", name: "Личный", color: "#3b82f6", access: .write)],
                events: ["personal": [dentist]]),
            workA: CalendarSyntheticAdapter(
                collections: [RemoteCollection(externalID: "work-a", name: "Работа A", color: "#10b981", access: .write)],
                events: ["work-a": [call, standup, invite, overlap]]),
            workB: CalendarSyntheticAdapter(
                collections: [RemoteCollection(externalID: "work-b", name: "Работа B", color: "#f59e0b", access: .write)],
                events: ["work-b": [telemost]],
                schedules: false),
            holidays: CalendarSyntheticAdapter(
                collections: [
                    RemoteCollection(externalID: "https://holidays.qa.test/ru.ics", name: "Праздники", color: "#64748b", access: .read)
                ],
                events: ["https://holidays.qa.test/ru.ics": [holiday]]),
        ]
    }

    /// Connects the synthetic accounts, groups the calendars and leaves one unknown write; a second run changes nothing.
    public static func seed(service: CalendarService, adapters: [String: CalendarSyntheticAdapter], now: Date) async throws {
        let store = service.store
        guard try await !store.accounts().contains(where: { $0.name == personal }) else { return }
        let weekdays = { (from: Int, to: Int) in
            CalendarWorkingHours(days: Dictionary(uniqueKeysWithValues: (1...5).map { ($0, [from...to]) }))
        }
        let accounts = [
            CalendarAccount(kind: .google, name: personal, googleGrantID: "qa-personal"),
            CalendarAccount(kind: .google, name: workA, workingHours: weekdays(540, 900), googleGrantID: "qa-work-a"),
            CalendarAccount(
                kind: .caldav, name: workB, workingHours: weekdays(900, 1080), caldavServer: URL(string: "https://caldav.yandex.ru"),
                caldavLogin: "me@yandex.test", serverSchedules: false),
            CalendarAccount(kind: .subscription, name: holidays, subscriptionURL: URL(string: "https://holidays.qa.test/ru.ics")),
        ]
        for account in accounts {
            try await store.saveAccount(account)
            try await service.refreshCollections(accountID: account.id)
            await service.sync(accountID: account.id)
        }
        let local = try await store.localAccount().1
        let base = day(now)
        _ = try await service.create(
            CalendarDraft(
                collectionID: local.id, title: "Зарядка",
                time: .timed(start: base.addingTimeInterval(8 * 3600), end: base.addingTimeInterval(8.5 * 3600), timeZone: nil),
                recurrence: CalendarRecurrence(rrule: "FREQ=DAILY")), ignoringConflicts: true)
        let group = CalendarGroup(name: "Все")
        let collections = try await store.collections().map { collection -> CalendarCollection in
            var value = collection
            if collection.access == .write { value.groupIDs = [group.id] }
            return value
        }
        try await service.applyGroupChange(collections: collections, groups: [group])
        // One write to the Yandex calendar whose answer is lost: the card offers «Проверить» and «Отказаться».
        await adapters[workB]?.failNext(.unknownOutcome(stage: "create"))
        if let workB = try await store.collections().first(where: { $0.externalID == "work-b" }) {
            _ = try await service.create(
                CalendarDraft(
                    collectionID: workB.id, title: "Созвон с подрядчиком",
                    time: .timed(
                        start: base.addingTimeInterval(2 * 86400 + 11 * 3600), end: base.addingTimeInterval(2 * 86400 + 12 * 3600),
                        timeZone: nil),
                    attendees: ["contractor@vendor.test"]), ignoringConflicts: true)
        }
    }
}

/// Tasks for the QA task column.
package struct CalendarSyntheticTaskFeed: CalendarTaskFeed {
    package init() {}
    static let items = [
        CalendarTaskItem(
            id: UUID(uuidString: "7A5B0000-0000-4000-8000-000000000301")!, title: "Подготовить отчёт за неделю", estimateMinutes: 60,
            due: Date(), overdue: false),
        CalendarTaskItem(
            id: UUID(uuidString: "7A5B0000-0000-4000-8000-000000000302")!, title: "Ревью pull request", estimateMinutes: 30, due: nil,
            overdue: false),
        CalendarTaskItem(
            id: UUID(uuidString: "7A5B0000-0000-4000-8000-000000000303")!, title: "Оплатить счёт за хостинг", estimateMinutes: 15,
            due: Date().addingTimeInterval(-86400 * 2), overdue: true),
        CalendarTaskItem(
            id: UUID(uuidString: "7A5B0000-0000-4000-8000-000000000304")!, title: "Звонок юристу", estimateMinutes: nil, due: nil,
            overdue: false),
    ]
    package func tasks(agenda: CalendarTaskAgenda) async -> [CalendarTaskItem] { Self.items }
    package func dueMarks(in interval: DateInterval) async -> [Date: [CalendarTaskItem]] {
        Dictionary(grouping: Self.items.filter { $0.due.map(interval.contains) ?? false }) { Calendar.current.startOfDay(for: $0.due!) }
    }
    package func setEstimate(taskID: UUID, minutes: Int) async {}
}
