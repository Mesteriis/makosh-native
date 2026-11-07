import Foundation

/// Focus sessions on top of the one timer: the active session is the task
/// the timer runs on. Switching keeps the previous task's time in its
/// session; only ending a session yields a time draft, never an entry.
public actor TaskFocusService {
    public enum PomodoroCommand: Sendable {
        case start(minutes: Int), pause, resume, stop
    }

    private let store: TaskStore
    private let time: TaskTimeService
    private let now: @Sendable () -> Date
    private var cached: TaskFocusState?

    public init(store: TaskStore, time: TaskTimeService, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.time = time
        self.now = now
    }

    public func state() async -> TaskFocusState {
        if let cached { return cached }
        let loaded = (try? await store.focusState()) ?? TaskFocusState()
        cached = loaded
        return loaded
    }

    private func save(_ state: TaskFocusState) async throws {
        cached = state
        try await store.saveFocusState(state)
    }

    // MARK: Sessions

    /// Brings a task into focus: the previous active task's running stretch is kept, the timer moves.
    @discardableResult public func focus(taskID: UUID) async throws -> TaskFocusState {
        var state = await state()
        if let active = state.active, active.taskID != taskID { try await stopTimerKeepingTime(into: &state) }
        state.focus(taskID: taskID, now: now())
        try await alignTimer(&state)
        try await save(state)
        return state
    }

    /// The active session waits; its time stays in the session.
    public func park() async throws {
        var state = await state()
        try await stopTimerKeepingTime(into: &state)
        state.park(now: now())
        try await save(state)
    }

    /// Drops a session; waiting time of a minute or more becomes a draft.
    public func remove(taskID: UUID) async throws -> TaskTimeDraft? {
        var state = await state()
        let draft = try await endSession(taskID: taskID, in: &state)
        try await save(state)
        return draft
    }

    /// «Сделано» on the panel: the session ends with a draft; the caller sets the status.
    public func done(taskID: UUID) async throws -> TaskTimeDraft? { try await remove(taskID: taskID) }

    /// «■» in the status bar.
    public func stopActive() async throws -> TaskTimeDraft? {
        guard let active = await state().active else { return nil }
        return try await remove(taskID: active.taskID)
    }

    /// Sessions of tasks closed, cancelled or deleted elsewhere end; their time becomes drafts.
    public func tasksClosed(_ ids: [UUID]) async throws -> [TaskTimeDraft] {
        var state = await state()
        var drafts: [TaskTimeDraft] = []
        for id in ids where state.session(of: id) != nil {
            if let draft = try await endSession(taskID: id, in: &state) { drafts.append(draft) }
        }
        if !drafts.isEmpty || state != cached { try await save(state) }
        return drafts
    }

    /// Turning the panel on while a timer runs: that task becomes the active session.
    public func adoptRunningTimer() async throws {
        guard let timer = try await store.timer() else { return }
        var state = await state()
        if state.active?.taskID == timer.taskID { return }
        state.park(now: now())
        state.focus(taskID: timer.taskID, now: timer.startedAt)
        if let index = state.sessions.firstIndex(where: { $0.taskID == timer.taskID }) {
            state.sessions[index].activeSince = timer.startedAt
        }
        try await save(state)
    }

    /// After a launch: an expired interval resets; an active session whose timer is gone is parked.
    public func restoreOnLaunch() async throws {
        var state = await state()
        state.restoreOnLaunch(now: now())
        if let active = state.active {
            if let timer = try await store.timer(), timer.taskID == active.taskID {
                if let index = state.sessions.firstIndex(where: { $0.taskID == active.taskID }), !state.pomodoro.isPaused {
                    state.sessions[index].activeSince = timer.startedAt
                }
            } else {
                state.park(now: now())
            }
        }
        try await save(state)
    }

    // MARK: Pomodoro

    public func pomodoro(_ command: PomodoroCommand) async throws {
        var state = await state()
        switch command {
        case .start(let minutes): state.startPomodoro(minutes: max(1, min(480, minutes)), now: now())
        case .pause:
            try await stopTimerKeepingTime(into: &state)
            state.pause(now: now())
        case .resume: state.resume(now: now())
        case .stop: state.stop(now: now())
        }
        try await alignTimer(&state)
        try await save(state)
    }

    /// Called every second while an interval runs; returns the phase that just ended.
    public func tickPhase(breakMinutes: Int) async throws -> TaskPomodoro.Phase? {
        var state = await state()
        guard state.pomodoro.phase != .idle, state.remaining(now: now()) <= 0 else { return nil }
        if state.pomodoro.phase == .work { try await stopTimerKeepingTime(into: &state) }
        let ended = state.completePhase(now: now(), breakMinutes: breakMinutes)
        try await alignTimer(&state)
        try await save(state)
        return ended
    }

    // MARK: Internals

    /// The state is the one ledger of attributed time: the running stretch is
    /// folded in by `activeSince`, the timer is only cleared.
    private func stopTimerKeepingTime(into state: inout TaskFocusState) async throws {
        _ = try await time.stopKeepingTime()
        state.flushActive(upTo: now())
    }

    /// Invariant: the active session with a running clock has the timer, started
    /// when its clock started; nobody else does.
    private func alignTimer(_ state: inout TaskFocusState) async throws {
        let timer = try await store.timer()
        guard let active = state.active, !state.pomodoro.isPaused else {
            if timer != nil { try await stopTimerKeepingTime(into: &state) }
            return
        }
        if let timer, timer.taskID == active.taskID {
            if let since = active.activeSince {
                if since != timer.startedAt {
                    try await store.saveTimer(TaskTimer(taskID: timer.taskID, startedAt: since, note: timer.note))
                }
            } else if let index = state.sessions.firstIndex(where: { $0.taskID == active.taskID }) {
                state.sessions[index].activeSince = timer.startedAt
            }
            return
        }
        if timer != nil { try await stopTimerKeepingTime(into: &state) }
        let started = try await time.start(taskID: active.taskID, note: "")
        if let index = state.sessions.firstIndex(where: { $0.taskID == active.taskID }) {
            state.sessions[index].activeSince = started.startedAt
        }
    }

    private func endSession(taskID: UUID, in state: inout TaskFocusState) async throws -> TaskTimeDraft? {
        guard let session = state.session(of: taskID) else { return nil }
        if session.state == .active { try await stopTimerKeepingTime(into: &state) }
        let total = state.session(of: taskID)?.accumulatedSeconds ?? 0
        state.remove(taskID: taskID, now: now())
        try await alignTimer(&state)
        guard total >= 60 else { return nil }
        return await time.draft(session: taskID, startedAt: now().addingTimeInterval(-TimeInterval(total)), seconds: total, note: "")
    }
}
