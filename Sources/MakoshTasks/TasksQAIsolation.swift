import CPostgres
import Foundation
import MakoshCore

/// The synthetic preview may only run against an explicitly supplied,
/// loopback-only configuration whose schema carries the `qa_tasks_` prefix.
public enum TasksQAIsolation {
    public static let flag = "--tasks-synthetic-preview"
    public static let schemaPrefix = "qa_tasks_"
    public enum Failure: Error, Equatable { case invalidConfiguration }

    public static func validate(configuration: PersonWorkspaceConfiguration, arguments: [String]) throws {
        let flags = [flag, "--database-config"]
        guard flags.allSatisfy({ flag in arguments.filter { $0 == flag }.count == 1 }),
            arguments.filter({ $0.hasPrefix("--") }).allSatisfy({ flags.contains($0) }),
            let index = arguments.firstIndex(of: "--database-config"), arguments.indices.contains(index + 1),
            arguments[index + 1].hasPrefix("/"), !arguments[index + 1].utf8.contains(0)
        else { throw Failure.invalidConfiguration }
        let schemas = [configuration.schema, configuration.archiveSchema ?? configuration.schema]
        guard
            schemas.allSatisfy({ schema in
                schema.hasPrefix(schemaPrefix) && schema.utf8.count > schemaPrefix.utf8.count && schema.utf8.count <= 63
                    && schema.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
            }), !configuration.connectionString.utf8.contains(0)
        else { throw Failure.invalidConfiguration }
        var error: UnsafeMutablePointer<CChar>?
        guard let parsed = PQconninfoParse(configuration.connectionString, &error) else {
            if let error { PQfreemem(error) }
            throw Failure.invalidConfiguration
        }
        defer {
            PQconninfoFree(parsed)
            if let error { PQfreemem(error) }
        }
        var values: [String: String] = [:]
        var position = 0
        while let keyword = parsed[position].keyword {
            if let value = parsed[position].val { values[String(cString: keyword)] = String(cString: value) }
            position += 1
        }
        let allowed: Set<String> = [
            "host", "hostaddr", "port", "dbname", "user", "password", "sslmode", "connect_timeout", "application_name",
        ]
        guard Set(values.keys).isSubset(of: allowed), ["127.0.0.1", "::1", "localhost"].contains(values["host"] ?? ""),
            ["127.0.0.1", "::1"].contains(values["hostaddr"] ?? "")
        else { throw Failure.invalidConfiguration }
        if let port = values["port"], Int(port).map({ (1...65535).contains($0) }) != true { throw Failure.invalidConfiguration }
    }
}

/// Twelve local tasks and one synthetic connection, with fixed ids so a
/// second seeding changes nothing; plus personas, a recurrence, two flows,
/// a plan for today and a waiting focus session for the interface's QA.
public enum TasksSyntheticSeed {
    public static let connectionID = UUID(uuidString: "6A7E4C2B-0000-4000-8000-0000000A5A5A")!
    public static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "7A5B%04X-0000-4000-8000-%012d", n * 2749, n))! }
    static func fixed(_ n: Int) -> UUID { UUID(uuidString: String(format: "7A5B0000-0000-4000-8000-%012d", n))! }

    public static func seed(store: TaskStore, now: Date = Date()) async throws {
        guard try await store.task(id: id(1)) == nil else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        let rows: [Task] = [
            Task(
                id: id(1), title: "Оплатить счёт за хостинг", status: .active, priority: 1, list: "Финансы", tags: ["оплата"], due: day(-3),
                createdAt: now),
            Task(
                id: id(2), title: "Подготовить отчёт за неделю", status: .active, priority: 2, list: "Работа", tags: ["отчёт"],
                personas: ["Боб"], due: day(0), estimateMinutes: 60, createdAt: now),
            Task(
                id: id(3), title: "Собрать релиз", status: .inbox, priority: 2, list: "Работа", tags: ["релиз"], due: day(1),
                flowID: "Релиз", createdAt: now),
            Task(
                id: id(4), title: "Выложить релиз", status: .inbox, priority: 2, list: "Работа", tags: ["релиз"], personas: ["Алиса"],
                due: day(2), dependsOn: [id(3)], flowID: "Релиз", createdAt: now),
            Task(
                id: id(5), title: "Написать заметки к релизу", status: .inbox, priority: 3, list: "Работа", dependsOn: [id(3), id(4)],
                flowID: "Релиз", createdAt: now),
            Task(
                id: id(6), title: "Записаться к стоматологу", status: .inbox, priority: 3, list: "Личное", tags: ["здоровье"], due: day(5),
                createdAt: now),
            Task(id: id(7), title: "Продлить страховку", status: .inbox, priority: 1, list: "Личное", due: day(12), createdAt: now),
            Task(
                id: id(8), title: "Прочитать договор аренды", status: .active, priority: 4, list: "Личное", tags: ["документы"],
                createdAt: now),
            Task(
                id: id(9), title: "Купить подарок", status: .done, priority: 4, list: "Личное", due: day(-1), createdAt: now,
                completedAt: now),
            Task(id: id(10), title: "Старая идея", status: .cancelled, priority: 4, createdAt: now),
            Task(
                id: id(11), title: "Разобрать почту", status: .inbox, priority: 4, tags: ["рутина"], personas: ["Боб", "Алиса"],
                estimateMinutes: 30, recurrence: "weekly", createdAt: now),
            Task(
                id: id(12), title: "Перенести заметки", status: .inbox, priority: 3, list: "Личное", due: day(0), postponed: 2,
                notes: [
                    TaskNote(id: fixed(112), content: "Переносилось дважды.", createdAt: now),
                    TaskNote(id: fixed(113), content: "Сначала выгрузить старый архив.", createdAt: now.addingTimeInterval(60)),
                ],
                createdAt: now),
            Task(
                id: id(13), title: "Выбрать плитку", status: .inbox, priority: 3, list: "Дом", tags: ["ремонт"], due: day(4),
                flowID: "Ремонт", createdAt: now),
            Task(
                id: id(14), title: "Вызвать мастера", status: .inbox, priority: 3, list: "Дом", tags: ["ремонт"], dependsOn: [id(13)],
                flowID: "Ремонт", createdAt: now),
        ]
        for row in rows { try await store.insert(row, actor: .user) }
        try await store.saveFlow(TaskFlow(name: "Релиз", description: "Выпуск 2.0", color: "#f472b6", deadline: day(10)))
        try await store.saveFlow(TaskFlow(name: "Ремонт", description: "Ванная", color: "#34d399"))
        let plan = try await store.plan(for: today, defaults: (9, 17), calendar: calendar)
        try await store.insertSlot(TaskPlanSlot(id: fixed(201), planID: plan.id, taskID: id(2), start: 10 * 60, end: 11 * 60, kind: .task))
        try await store.insertSlot(
            TaskPlanSlot(
                id: fixed(202), planID: plan.id, title: "Обед", start: 12 * 60 + 30, end: 13 * 60, kind: .blocked, recurrence: .daily))
        var focus = TaskFocusState()
        focus.sessions = [
            TaskFocusSession(taskID: id(8), state: .waiting, accumulatedSeconds: 420, waitingSince: now.addingTimeInterval(-900))
        ]
        try await store.saveFocusState(focus)
        try await store.saveConnection(
            JiraConnection(
                id: connectionID, name: "Синтетическая Jira", origin: URL(string: "https://jira.synthetic.test")!, email: "qa@example.com",
                accountID: "me-1"))
    }
}
