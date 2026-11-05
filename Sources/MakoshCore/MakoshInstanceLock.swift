import Foundation

/// One running copy per bundle identifier: an exclusive advisory lock on a
/// file, released by the kernel when the process exits, so a crash never
/// leaves a stale lock behind.
public final class MakoshInstanceLock: Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    /// Nil when another process (or another open of the same file) holds the lock.
    public static func acquire(at url: URL) -> MakoshInstanceLock? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return MakoshInstanceLock(descriptor: descriptor)
    }

    /// `~/Library/Application Support/Makosh/<bundle id>.lock`.
    public static func defaultURL(bundleIdentifier: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Makosh", isDirectory: true).appendingPathComponent(bundleIdentifier + ".lock")
    }
}
