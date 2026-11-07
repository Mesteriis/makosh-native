import Foundation

/// The focus panel's commands and the queue of time drafts.
extension TasksWorkspaceModel {
    public var focusEnabled: Bool { preferences.focus.enabled }
    public var focusConfig: TaskFocusConfig { preferences.focus }

    // MARK: Drafts

    /// Shows the draft now, or after the one on screen is settled.
    public func enqueue(_ draft: TaskTimeDraft) {
        if self.draft == nil { self.draft = draft } else { draftQueue.append(draft) }
    }

    func presentNextDraft() {
        draft = draftQueue.isEmpty ? nil : draftQueue.removeFirst()
    }

    // MARK: Sessions

    public func setFocusEnabled(_ enabled: Bool) async {
        updatePreferences { $0.focus.enabled = enabled }
        if enabled {
            do {
                try await service.focus.adoptRunningTimer()
                await syncFocusState()
            } catch { self.error = Self.describe(error) }
        }
        objectWillChange.send()
    }

    public func focus(id: UUID) async {
        do {
            focusState = try await service.focus.focus(taskID: id)
            timer = try await service.time.timer()
            error = nil
            startTicking()
            tick()
        } catch { self.error = Self.describe(error) }
    }

    public func park() async {
        do {
            try await service.focus.park()
            await syncFocusState()
        } catch { self.error = Self.describe(error) }
    }

    public func removeFromFocus(id: UUID) async {
        do {
            if let draft = try await service.focus.remove(taskID: id) { enqueue(draft) }
            await syncFocusState()
        } catch { self.error = Self.describe(error) }
    }

    /// «Сделано» on the panel: the session's time becomes a draft and the task closes.
    public func focusDone(id: UUID) async {
        do {
            if let draft = try await service.focus.done(taskID: id) { enqueue(draft) }
            await syncFocusState()
            await set(status: .done, id: id)
        } catch { self.error = Self.describe(error) }
    }

    func stopFocusSession() async {
        do {
            if let draft = try await service.focus.stopActive() { enqueue(draft) }
            await syncFocusState()
        } catch { self.error = Self.describe(error) }
    }

    public func pomodoro(_ command: TaskFocusService.PomodoroCommand) async {
        do {
            try await service.focus.pomodoro(command)
            await syncFocusState()
        } catch { self.error = Self.describe(error) }
    }

    /// Runs with the ticking task: an elapsed interval moves on and says so.
    func tickPomodoro() {
        guard focusState.pomodoro.phase != .idle, focusState.remaining(now: now()) <= 0 else { return }
        let breakMinutes = focusConfig.breakMinutes
        _Concurrency.Task {
            guard let ended = try? await service.focus.tickPhase(breakMinutes: breakMinutes) else { return }
            await syncFocusState()
            toast(ended == .work ? "Интервал завершён" : "Перерыв окончен")
        }
    }

    func syncFocusState() async {
        focusState = await service.focus.state()
        timer = try? await service.time.timer()
        if timer != nil { startTicking() }
        tick()
    }

    /// Sessions of tasks closed, cancelled or deleted by any path end with a draft; a
    /// provider's closing says so on the sheet.
    func settleClosedFocusSessions() async {
        let gone = focusState.sessions.map(\.taskID).filter { id in
            guard let task = task(id: id) else { return true }
            return task.status == .done || task.status == .cancelled || task.deletedAt != nil
        }
        guard !gone.isEmpty else { return }
        do {
            let drafts = try await service.focus.tasksClosed(gone)
            for var draft in drafts {
                if let versions = try? await service.store.versions(taskID: draft.taskID), versions.last?.actor == .provider {
                    draft.reason = "задача закрыта в Jira"
                }
                enqueue(draft)
            }
            await syncFocusState()
        } catch { self.error = Self.describe(error) }
    }
}
