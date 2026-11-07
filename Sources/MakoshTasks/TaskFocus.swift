import Foundation

/// One task in focus: active (attention is single-threaded) or waiting.
/// `accumulatedSeconds` is attributed work; waiting time is shown, never counted.
public struct TaskFocusSession: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case active, waiting }
    public let taskID: UUID
    public var state: State
    public var accumulatedSeconds: Int
    /// Set while the attribution clock runs (active and not paused).
    public var activeSince: Date?
    public var waitingSince: Date?

    public init(taskID: UUID, state: State, accumulatedSeconds: Int = 0, activeSince: Date? = nil, waitingSince: Date? = nil) {
        self.taskID = taskID
        self.state = state
        self.accumulatedSeconds = accumulatedSeconds
        self.activeSince = activeSince
        self.waitingSince = waitingSince
    }
}

/// The interval timer, bound to attention rather than to a task.
public struct TaskPomodoro: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case idle, work, `break` }
    public var phase: Phase = .idle
    public var startedAt: Date?
    public var plannedMinutes = 0
    public var pausedAt: Date?
    public var pausedSeconds = 0
    public init() {}

    static let idle = TaskPomodoro()

    var isPaused: Bool { phase == .break || (phase == .work && pausedAt != nil) }
}

/// The focus state machine of the reference, wall-clock driven: every
/// transition takes `now`, nothing ticks. The service keeps the timer in step.
public struct TaskFocusState: Codable, Equatable, Sendable {
    public var sessions: [TaskFocusSession] = []
    public var pomodoro = TaskPomodoro()
    /// Completed work intervals per local day (yyyy-MM-dd).
    public var counts: [String: Int] = [:]
    public var savedAt: Date?

    public init() {}

    public var active: TaskFocusSession? { sessions.first { $0.state == .active } }
    public var waiting: [TaskFocusSession] { sessions.filter { $0.state == .waiting } }
    public func session(of taskID: UUID) -> TaskFocusSession? { sessions.first { $0.taskID == taskID } }

    // MARK: Sessions

    /// The task becomes the active session; the previous active one waits.
    public mutating func focus(taskID: UUID, now: Date) {
        flushActive(upTo: now)
        for index in sessions.indices where sessions[index].state == .active && sessions[index].taskID != taskID {
            sessions[index].state = .waiting
            sessions[index].waitingSince = now
        }
        let since: Date? = pomodoro.isPaused ? nil : now
        if let index = sessions.firstIndex(where: { $0.taskID == taskID }) {
            sessions[index].state = .active
            sessions[index].waitingSince = nil
            sessions[index].activeSince = since
        } else {
            sessions.append(TaskFocusSession(taskID: taskID, state: .active, activeSince: since))
        }
    }

    /// The active session waits; nothing becomes active.
    public mutating func park(now: Date) {
        flushActive(upTo: now)
        for index in sessions.indices where sessions[index].state == .active {
            sessions[index].state = .waiting
            sessions[index].waitingSince = now
        }
    }

    public mutating func remove(taskID: UUID, now: Date) {
        flushActive(upTo: now)
        sessions.removeAll { $0.taskID == taskID }
        restartActiveClock(now: now)
    }

    // MARK: Pomodoro

    public mutating func startPomodoro(minutes: Int, now: Date) {
        var value = TaskPomodoro()
        value.phase = .work
        value.startedAt = now
        value.plannedMinutes = minutes
        pomodoro = value
        restartActiveClock(now: now)
    }

    public mutating func pause(now: Date) {
        guard pomodoro.phase == .work, pomodoro.pausedAt == nil else { return }
        flushActive(upTo: now)
        pomodoro.pausedAt = now
    }

    public mutating func resume(now: Date) {
        guard pomodoro.phase == .work, let pausedAt = pomodoro.pausedAt else { return }
        pomodoro.pausedSeconds += max(0, Int(now.timeIntervalSince(pausedAt)))
        pomodoro.pausedAt = nil
        restartActiveClock(now: now)
    }

    /// Aborts the interval without counting it; attribution keeps running.
    public mutating func stop(now: Date) {
        pomodoro = .idle
        restartActiveClock(now: now)
    }

    public func remaining(now: Date) -> TimeInterval {
        guard pomodoro.phase != .idle, let startedAt = pomodoro.startedAt else { return 0 }
        let end = startedAt.addingTimeInterval(TimeInterval(pomodoro.plannedMinutes * 60 + pomodoro.pausedSeconds))
        let effective = pomodoro.pausedAt ?? now
        return max(0, end.timeIntervalSince(effective))
    }

    /// Advances an elapsed phase; returns the phase that ended, nil when nothing ended.
    @discardableResult
    public mutating func completePhase(now: Date, breakMinutes: Int) -> TaskPomodoro.Phase? {
        guard pomodoro.phase != .idle, remaining(now: now) <= 0 else { return nil }
        if pomodoro.phase == .work {
            let day = Self.dayKey(now)
            counts[day, default: 0] += 1
            if breakMinutes > 0 {
                flushActive(upTo: now)
                var value = TaskPomodoro()
                value.phase = .break
                value.startedAt = now
                value.plannedMinutes = breakMinutes
                pomodoro = value
            } else {
                pomodoro = .idle
            }
            return .work
        }
        pomodoro = .idle
        restartActiveClock(now: now)
        return .break
    }

    // MARK: Reading

    public func workSeconds(of taskID: UUID, now: Date) -> Int {
        guard let session = session(of: taskID) else { return 0 }
        let running = session.activeSince.map { max(0, Int(now.timeIntervalSince($0))) } ?? 0
        return session.accumulatedSeconds + running
    }

    public func waitingSeconds(of taskID: UUID, now: Date) -> Int {
        guard let session = session(of: taskID), session.state == .waiting, let since = session.waitingSince else { return 0 }
        return max(0, Int(now.timeIntervalSince(since)))
    }

    public func todayCount(now: Date, calendar: Calendar) -> Int { counts[Self.dayKey(now, calendar: calendar)] ?? 0 }

    /// After a launch: an interval that ended while the app was closed is not
    /// counted; sessions stay as they were (the timer outlives restarts).
    public mutating func restoreOnLaunch(now: Date) {
        if pomodoro.phase != .idle, remaining(now: now) > 0 { return }
        pomodoro = .idle
    }

    // MARK: Internals

    mutating func flushActive(upTo now: Date) {
        for index in sessions.indices where sessions[index].state == .active {
            if let since = sessions[index].activeSince {
                sessions[index].accumulatedSeconds += max(0, Int(now.timeIntervalSince(since)))
                sessions[index].activeSince = nil
            }
        }
    }

    private mutating func restartActiveClock(now: Date) {
        guard !pomodoro.isPaused else { return }
        for index in sessions.indices where sessions[index].state == .active && sessions[index].activeSince == nil {
            sessions[index].activeSince = now
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String { TasksFilters.dayString(date, calendar: calendar) }
}

extension TaskStore {
    public func focusState() throws -> TaskFocusState? {
        try query("SELECT data FROM \(t("tasks_focus")) WHERE id = 1").first.map { try decode(TaskFocusState.self, $0[0]) }
    }

    public func saveFocusState(_ state: TaskFocusState) throws {
        var value = state
        value.savedAt = Self.millis(now())
        try execute(
            "INSERT INTO \(t("tasks_focus"))(id, data) VALUES(1, $1::jsonb) ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data",
            [try encode(value)])
    }
}
