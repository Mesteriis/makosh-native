import Foundation

/// Tracks one live window. Request tokens reject delayed emissions from replaced windows.
struct TelegramPageTracker<Cursor: Equatable> {
    enum Status: Equatable {
        case idle, loading, ready, timedOut
    }

    private(set) var requestID: UUID?
    private(set) var anchor: Cursor?
    private(set) var previousCursor: Cursor?
    private(set) var nextCursor: Cursor?
    private(set) var hasPreviousGap = false
    private(set) var hasNextGap = false
    private(set) var status: Status = .idle

    var canLoadPrevious: Bool {
        (status == .ready || status == .timedOut) && previousCursor != nil && previousCursor != anchor
    }

    var canLoadNext: Bool {
        (status == .ready || status == .timedOut) && nextCursor != nil && nextCursor != anchor
    }

    var isAtLatest: Bool { anchor == nil }

    mutating func begin(anchor: Cursor?) -> UUID {
        reset()
        let token = UUID()
        requestID = token
        self.anchor = anchor
        status = .loading
        return token
    }

    @discardableResult
    mutating func update(requestID: UUID, previous: Cursor?, next: Cursor?, isLoading: Bool,
                         hasPreviousGap: Bool = false, hasNextGap: Bool = false) -> Bool {
        guard self.requestID == requestID else { return false }
        previousCursor = previous
        nextCursor = next
        self.hasPreviousGap = hasPreviousGap
        self.hasNextGap = hasNextGap
        // A live subscription may recover after its UI deadline has elapsed.
        if !isLoading {
            status = .ready
        } else if status != .timedOut {
            status = .loading
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
        anchor = nil
        previousCursor = nil
        nextCursor = nil
        hasPreviousGap = false
        hasNextGap = false
        status = .idle
    }
}
