import Foundation

/// One CPU worker and four admitted owned jobs bound pending source retention.
final class TelegramCodeHighlightQueue: @unchecked Sendable {
    let queue = DispatchQueue(label: "makosh.code-highlight", qos: .userInitiated)
    private let lock = NSLock()
    private var admitted = 0

    func admit() -> Bool {
        lock.withLock {
            guard admitted < 4 else { return false }
            admitted += 1
            return true
        }
    }
    func release() { lock.withLock { admitted -= 1 } }
}
