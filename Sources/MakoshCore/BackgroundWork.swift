import Foundation

/// A bounded synchronous preparation step must explicitly leave its caller's
/// actor. Cancellation remains in the caller's task and rejects stale results.
public enum BackgroundWork {
    @concurrent public static func run<Value: Sendable>(
        _ operation: @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let value = try operation()
        try Task.checkCancellation()
        return value
    }
}
