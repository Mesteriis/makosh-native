import Foundation

public enum TelegramSearchStatus: Equatable, Sendable {
    case idle, loading, ready, failed, timedOut
}

/// Retains the last successful opaque pagination state while a page is retried.
/// The controller resets this tracker whenever its account, query or scope changes.
struct TelegramSearchTracker<State> {
    private(set) var requestID: UUID?
    private(set) var state: State?
    private(set) var completed = false
    private(set) var status: TelegramSearchStatus = .idle

    var canLoadMore: Bool { status == .ready && !completed }
    var canRetry: Bool { status == .failed || status == .timedOut }

    mutating func begin() -> UUID {
        let token = UUID()
        requestID = token
        status = .loading
        return token
    }

    @discardableResult
    mutating func receive(requestID: UUID, state: State, completed: Bool, failed: Bool) -> Bool {
        guard self.requestID == requestID else { return false }
        if failed {
            status = .failed
        } else {
            self.state = state
            self.completed = completed
            status = .ready
        }
        return true
    }

    @discardableResult
    mutating func timeout(requestID: UUID) -> Bool {
        guard self.requestID == requestID, status == .loading else { return false }
        status = .timedOut
        return true
    }

    mutating func reset() {
        requestID = nil
        state = nil
        completed = false
        status = .idle
    }
}
