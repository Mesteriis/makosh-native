import Foundation
import CoreGraphics
import Postbox

public struct TelegramHistoryReadContext: Equatable, Hashable, Sendable {
    public let accountID: Int64
    public let chatID: Int64
    public let accountContextID: UUID
    public let historyWindowID: UUID
    public init(accountID: Int64, chatID: Int64, accountContextID: UUID, historyWindowID: UUID) {
        self.accountID = accountID; self.chatID = chatID
        self.accountContextID = accountContextID; self.historyWindowID = historyWindowID
    }
}

internal struct TelegramHistoryReadTarget: Equatable {
    let context: TelegramHistoryReadContext
    let index: MessageIndex
}

@MainActor internal protocol TelegramHistoryReadProvider: AnyObject {
    var accountID: Int64 { get }
    /// True means local transaction completion, never a server acknowledgment.
    func apply(_ target: TelegramHistoryReadTarget, completion: @escaping @MainActor (Bool) -> Void)
}

@MainActor internal final class TelegramHistoryReadController {
    private struct Key: Hashable {
        let peer: PeerId
        let namespace: Int32
    }
    private var provider: (any TelegramHistoryReadProvider)?
    private var generation = UUID()
    private var applied: [Key: MessageIndex] = [:]
    private var pending: [Key: [UUID: MessageIndex]] = [:]

    func bind(_ provider: (any TelegramHistoryReadProvider)?) {
        generation = UUID(); self.provider = provider
        applied = [:]; pending = [:]
    }

    @discardableResult func apply(_ target: TelegramHistoryReadTarget) -> Bool {
        guard let provider, provider.accountID == target.context.accountID else { return false }
        let key = Key(peer: target.index.id.peerId, namespace: target.index.id.namespace)
        if let index = applied[key], target.index <= index { return false }
        if pending[key]?.values.contains(where: { target.index <= $0 }) == true { return false }
        let request = UUID(), token = generation
        pending[key, default: [:]][request] = target.index
        provider.apply(target) { [weak self] success in
            guard let self, self.generation == token,
                  self.pending[key]?.removeValue(forKey: request) != nil else { return }
            if self.pending[key]?.isEmpty == true { self.pending.removeValue(forKey: key) }
            if success, self.applied[key].map({ $0 < target.index }) ?? true {
                self.applied[key] = target.index
            }
            // Failure removes only this admission, allowing future visible-row
            // submission. No timers or automatic network retries are introduced.
        }
        return true
    }
}

public enum TelegramHistoryReadVisibility {
    public static func isVisible(row: CGRect, viewport: CGRect) -> Bool {
        func valid(_ rect: CGRect) -> Bool {
            rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
                rect.width > 0 && rect.height > 0 && rect.maxX.isFinite && rect.maxY.isFinite
        }
        guard valid(row), valid(viewport) else { return false }
        let visible = row.intersection(viewport)
        return !visible.isNull && visible.width > 0 && visible.height > 0 && visible.height >= row.height - 10
    }
}
