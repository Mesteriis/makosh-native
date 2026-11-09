import Foundation

/// Synthetic OSINT QA never leaves the Mac: the SSH fixture and the synthetic flowsint live on loopback.
public enum OSINTQAIsolation {
    public enum Failure: Error, Equatable { case invalidConfiguration }
    public static let loopbackHost = "127.0.0.1"

    /// In synthetic mode the configured server must be loopback; ordinary mode accepts any host.
    public static func validate(settings: OSINTSettings, synthetic: Bool) throws {
        guard synthetic else { return }
        guard settings.host == loopbackHost else { throw Failure.invalidConfiguration }
    }
}
