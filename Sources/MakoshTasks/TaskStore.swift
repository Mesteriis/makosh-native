import Foundation
import MakoshCore
import MakoshJira

public enum TaskStoreError: Error, Equatable, Sendable {
    case notOpen
    case invalidSchema
    case staleRevision
    case notFound
    case duplicate
    case invalidTransition
    case storage(String?)
}

/// Who made a change: the user in Makosh, or a provider's observation.
public enum TaskActor: String, Codable, Sendable {
    case user
    case provider
}

public struct TaskVersion: Codable, Equatable, Sendable {
    public let revision: Int64
    public let actor: TaskActor
    public let changedFields: [String]
    public let task: Task
    public let at: Date
}

/// What the provider showed for an issue at one moment; kept as received.
public struct TaskProviderObservation: Codable, Equatable, Sendable {
    public let identity: ServiceIdentity
    public let observedAt: Date
    public let raw: Data
    public var issue: JiraIssue
    public var comments: [JiraComment]
    public var myWorklogs: [JiraWorklog]
    public var transitions: [JiraTransition]
    public init(
        identity: ServiceIdentity, observedAt: Date, raw: Data, issue: JiraIssue, comments: [JiraComment] = [],
        myWorklogs: [JiraWorklog] = [], transitions: [JiraTransition] = []
    ) {
        self.identity = identity
        self.observedAt = observedAt
        self.raw = raw
        self.issue = issue
        self.comments = comments
        self.myWorklogs = myWorklogs
        self.transitions = transitions
    }
}

/// The section's PostgreSQL store. One connection, confined to the actor;
/// every write is a transaction that also appends a version row.
public actor TaskStore {
    private let connectionString: String
    let schema: String
    private var connection: PostgresConnection?
    private let encoder = TaskStore.makeEncoder()
    private let decoder = TaskStore.makeDecoder()
    let now: @Sendable () -> Date

    // JSONEncoder's own `.iso8601` drops fractional seconds; keep milliseconds both ways.
    static func makeEncoder() -> JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(TaskStore.iso(date))
        }
        value.outputFormatting = [.sortedKeys]
        return value
    }
    static func makeDecoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = TaskStore.date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "date"))
            }
            return date
        }
        return value
    }

    public init(connectionString: String, schema: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.connectionString = connectionString
        self.schema = schema
        self.now = now
    }

    public func open() throws {
        guard PostgresConnection.isValidSchemaName(schema) else { throw TaskStoreError.invalidSchema }
        if connection?.isOpen != true { connection = try wrap { try PostgresConnection(connectionString: connectionString) } }
        for statement in TaskStoreSchema.statements(schema: schema) { try execute(statement) }
    }

    public func close() {
        connection?.close()
        connection = nil
    }

    // MARK: Tasks

    public func tasks(includeDeleted: Bool = false) throws -> [Task] {
        let rows = try query(
            "SELECT data FROM \(t("tasks_tasks")) \(includeDeleted ? "" : "WHERE deleted_at IS NULL") ORDER BY updated_at DESC")
        return try rows.map { try decode(Task.self, $0[0]) }
    }

    public func task(id: UUID) throws -> Task? {
        try query("SELECT data FROM \(t("tasks_tasks")) WHERE id = $1", [id.uuidString]).first.map { try decode(Task.self, $0[0]) }
    }

    public func task(code: String) throws -> Task? {
        try query("SELECT data FROM \(t("tasks_tasks")) WHERE code = $1 AND deleted_at IS NULL", [code.uppercased()]).first.map {
            try decode(Task.self, $0[0])
        }
    }

    public func task(source identity: ServiceIdentity) throws -> Task? {
        let rows = try query(
            "SELECT t.data FROM \(t("tasks_sources")) s JOIN \(t("tasks_tasks")) t ON t.id = s.task_id WHERE s.identity = $1", [identity.id]
        )
        return try rows.first.map { try decode(Task.self, $0[0]) }
    }

    @discardableResult public func insert(_ task: Task, actor: TaskActor) throws -> Task {
        try insert(task, actor: actor, changed: ["*"])
    }

    @discardableResult func insert(_ task: Task, actor: TaskActor, changed: [String]) throws -> Task {
        // Stored dates carry millisecond precision; the returned value matches what a read gives back.
        var value = Self.rounded(task.replacing(createdAt: Self.millis(task.createdAt)))
        value.revision = 1
        value.updatedAt = Self.millis(now())
        try transaction {
            // A failed INSERT would poison the transaction, so the code is checked first;
            // a race on the UNIQUE index still surfaces as `duplicate`.
            for _ in 0..<4 where try !self.query("SELECT 1 FROM \(self.t("tasks_tasks")) WHERE code = $1", [value.code]).isEmpty {
                value = value.replacing(code: TaskCode.make(from: UUID()))
            }
            try self.write(value)
            if let source = value.source { try self.writeSource(source, taskID: value.id) }
            try self.appendVersion(value, actor: actor, changed: changed)
        }
        return value
    }

    /// Writes the task and, in the same transaction, whatever its status change
    /// entails: activated dependents, a spawned occurrence, a withdrawn one.
    @discardableResult public func update(_ task: Task, expectedRevision: Int64, actor: TaskActor) throws -> Task {
        try apply(task, expectedRevision: expectedRevision, actor: actor).task
    }

    public func apply(_ task: Task, expectedRevision: Int64, actor: TaskActor) throws -> TaskWriteResult {
        try transaction {
            guard let current = try self.task(id: task.id) else { throw TaskStoreError.notFound }
            let written = try self.update(task, expectedRevision: expectedRevision, actor: actor, extraChanged: [])
            let effects = try self.closingEffects(before: current, after: written, actor: actor)
            return TaskWriteResult(task: written, effects: effects)
        }
    }

    /// The bare write of one task; `extraChanged` names the rule that caused it.
    @discardableResult func update(_ task: Task, expectedRevision: Int64, actor: TaskActor, extraChanged: [String]) throws -> Task {
        var value = Self.rounded(task)
        try transaction {
            guard let current = try self.task(id: task.id) else { throw TaskStoreError.notFound }
            guard current.revision == expectedRevision else { throw TaskStoreError.staleRevision }
            value.revision = current.revision + 1
            value.updatedAt = Self.millis(self.now())
            let changed = Self.changedFields(from: current, to: value) + extraChanged
            try self.execute(
                "UPDATE \(self.t("tasks_tasks")) SET data = $2::jsonb, status = $3, due = $4, deleted_at = $5, revision = $6, updated_at = $7 WHERE id = $1",
                [
                    value.id.uuidString, try self.encode(value), value.status.rawValue, value.due.map(Self.dayString),
                    value.deletedAt.map(Self.iso),
                    String(value.revision), Self.iso(value.updatedAt),
                ])
            if let source = value.source { try self.writeSource(source, taskID: value.id) }
            try self.appendVersion(value, actor: actor, changed: changed)
        }
        return value
    }

    public func softDelete(id: UUID, expectedRevision: Int64, actor: TaskActor) throws {
        guard var task = try task(id: id) else { throw TaskStoreError.notFound }
        task.deletedAt = now()
        try update(task, expectedRevision: expectedRevision, actor: actor)
    }

    public func restore(id: UUID) throws {
        guard var task = try task(id: id) else { throw TaskStoreError.notFound }
        task.deletedAt = nil
        try update(task, expectedRevision: task.revision, actor: .user)
    }

    public func versions(taskID: UUID) throws -> [TaskVersion] {
        let rows = try query(
            "SELECT revision, actor, array_to_json(changed)::text, data, at FROM \(t("tasks_versions")) WHERE task_id = $1 ORDER BY seq",
            [taskID.uuidString])
        return try rows.map { row in
            TaskVersion(
                revision: Int64(row[0]) ?? 0, actor: TaskActor(rawValue: row[1]) ?? .user,
                changedFields: (try? decoder.decode([String].self, from: Data(row[2].utf8))) ?? [], task: try decode(Task.self, row[3]),
                at: Self.date(row[4]) ?? .distantPast)
        }
    }

    // MARK: Sources and observations

    public func setMembership(taskID: UUID, _ membership: TaskMembership) throws {
        try transaction {
            guard var task = try self.task(id: taskID), var source = task.source else { throw TaskStoreError.notFound }
            source.membership = membership
            task.source = source
            try self.update(task, expectedRevision: task.revision, actor: .provider)
        }
    }

    public func sources(connectionID: UUID) throws -> [(taskID: UUID, source: TaskSource)] {
        let rows = try query(
            "SELECT task_id, data FROM \(t("tasks_sources")) WHERE data->'identity'->>'accountID' = $1", [connectionID.uuidString])
        return try rows.compactMap { row in
            guard let id = UUID(uuidString: row[0]) else { return nil }
            return (id, try decode(TaskSource.self, row[1]))
        }
    }

    public func saveObservation(_ observation: TaskProviderObservation, for taskID: UUID) throws {
        try transaction {
            let data = try self.encode(observation)
            try self.execute(
                "INSERT INTO \(self.t("tasks_source_versions"))(identity, observed_at, data) VALUES($1, $2, $3::jsonb)",
                [observation.identity.id, Self.iso(observation.observedAt), data])
            try self.execute(
                "UPDATE \(self.t("tasks_sources")) SET observed_at = $2 WHERE identity = $1 AND task_id = $3",
                [observation.identity.id, Self.iso(observation.observedAt), taskID.uuidString])
        }
    }

    public func latestObservation(taskID: UUID) throws -> TaskProviderObservation? { try observations(taskID: taskID, limit: 1).first }

    public func observations(taskID: UUID, limit: Int) throws -> [TaskProviderObservation] {
        let rows = try query(
            """
            SELECT v.data FROM \(t("tasks_source_versions")) v JOIN \(t("tasks_sources")) s ON s.identity = v.identity
            WHERE s.task_id = $1 ORDER BY v.seq DESC LIMIT $2
            """, [taskID.uuidString, String(max(1, limit))])
        return try rows.map { try decode(TaskProviderObservation.self, $0[0]) }
    }

    // MARK: Preferences

    public func preferences() throws -> TaskPreferences {
        try query("SELECT data FROM \(t("tasks_preferences")) WHERE id = 1").first.map { try decode(TaskPreferences.self, $0[0]) }
            ?? TaskPreferences()
    }

    public func savePreferences(_ value: TaskPreferences) throws {
        try execute(
            "INSERT INTO \(t("tasks_preferences"))(id, data) VALUES(1, $1::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data",
            [try encode(value)])
    }

    // MARK: Internals shared with later extensions

    func t(_ table: String) -> String { "\"\(schema)\".\(table)" }

    private func write(_ task: Task) throws {
        do {
            try execute(
                """
                INSERT INTO \(t("tasks_tasks"))(id, code, data, status, due, deleted_at, revision, updated_at)
                VALUES($1, $2, $3::jsonb, $4, $5, $6, $7, $8)
                """,
                [
                    task.id.uuidString, task.code, try encode(task), task.status.rawValue, task.due.map(Self.dayString),
                    task.deletedAt.map(Self.iso),
                    String(task.revision), Self.iso(task.updatedAt),
                ])
        } catch let failure as PostgresConnection.Failure where failure.sqlState == "23505" {
            throw TaskStoreError.duplicate
        }
    }

    private func writeSource(_ source: TaskSource, taskID: UUID) throws {
        try execute(
            """
            INSERT INTO \(t("tasks_sources"))(identity, task_id, membership, data) VALUES($1, $2, $3, $4::jsonb)
            ON CONFLICT (identity) DO UPDATE SET membership = EXCLUDED.membership, data = EXCLUDED.data
            """, [source.identity.id, taskID.uuidString, source.membership.rawValue, try encode(source)])
    }

    private func appendVersion(_ task: Task, actor: TaskActor, changed: [String]) throws {
        let list = "{" + changed.map { "\"\($0)\"" }.joined(separator: ",") + "}"
        try execute(
            "INSERT INTO \(t("tasks_versions"))(task_id, revision, actor, changed, data, at) VALUES($1, $2, $3, $4::text[], $5::jsonb, $6)",
            [task.id.uuidString, String(task.revision), actor.rawValue, list, try encode(task), Self.iso(task.updatedAt)])
    }

    /// ISO 8601 output truncates to milliseconds; round the same way before writing.
    static func millis(_ date: Date) -> Date {
        let text = isoFormatter(fractional: true).string(from: date)
        return isoFormatter(fractional: true).date(from: text) ?? date
    }
    static func rounded(_ task: Task) -> Task {
        var value = task
        value.due = task.due.map(millis)
        value.start = task.start.map(millis)
        value.completedAt = task.completedAt.map(millis)
        value.deletedAt = task.deletedAt.map(millis)
        return value
    }

    static func changedFields(from old: Task, to new: Task) -> [String] {
        var fields: [String] = []
        if old.title != new.title { fields.append("title") }
        if old.status != new.status { fields.append("status") }
        if old.priority != new.priority { fields.append("priority") }
        if old.list != new.list { fields.append("list") }
        if old.tags != new.tags { fields.append("tags") }
        if old.personas != new.personas { fields.append("personas") }
        if old.due != new.due { fields.append("due") }
        if old.start != new.start { fields.append("start") }
        if old.estimateMinutes != new.estimateMinutes { fields.append("estimate") }
        if old.url != new.url { fields.append("url") }
        if old.postponed != new.postponed { fields.append("postponed") }
        if old.dependsOn != new.dependsOn { fields.append("dependsOn") }
        if old.recurrence != new.recurrence { fields.append("recurrence") }
        if old.flowID != new.flowID { fields.append("flowID") }
        if old.notes != new.notes { fields.append("notes") }
        if old.source != new.source { fields.append("source") }
        if old.completedAt != new.completedAt { fields.append("completedAt") }
        if old.deletedAt != new.deletedAt { fields.append("deletedAt") }
        return fields
    }

    func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try decoder.decode(type, from: Data(text.utf8)) }

    @discardableResult func query(_ sql: String, _ parameters: [String?] = []) throws -> [[String]] {
        guard let connection else { throw TaskStoreError.notOpen }
        return try wrap { try connection.query(sql, parameters) }
    }
    func execute(_ sql: String, _ parameters: [String?] = []) throws {
        guard let connection else { throw TaskStoreError.notOpen }
        try wrap { try connection.execute(sql, parameters) }
    }
    private var transactionDepth = 0

    /// One BEGIN/COMMIT for the outermost call; nested calls join it, so a
    /// failure anywhere rolls back everything (a bare inner COMMIT would not).
    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard let connection else { throw TaskStoreError.notOpen }
        if transactionDepth > 0 { return try body() }
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        return try connection.transaction(body)
    }

    /// Several store calls as one transaction; the closure runs on the actor.
    public func performInTransaction<T: Sendable>(_ body: @Sendable (isolated TaskStore) throws -> T) throws -> T {
        try transaction { try body(self) }
    }
    private func wrap<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let failure as PostgresConnection.Failure {
            if failure.sqlState == "23505" { throw TaskStoreError.duplicate }
            throw TaskStoreError.storage(failure.sqlState)
        }
    }

    private static func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let value = ISO8601DateFormatter()
        value.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return value
    }
    static func iso(_ date: Date) -> String { isoFormatter(fractional: true).string(from: date) }
    static func date(_ text: String) -> Date? {
        // PostgreSQL prints "2026-11-07 10:00:00.123+00"; normalise to ISO 8601.
        var value = text.replacingOccurrences(of: " ", with: "T")
        if let sign = value.lastIndex(where: { $0 == "+" || $0 == "-" }), value.distance(from: sign, to: value.endIndex) == 3 {
            value += ":00"
        }
        return isoFormatter(fractional: true).date(from: value) ?? isoFormatter(fractional: false).date(from: value)
    }
    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
