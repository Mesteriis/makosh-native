import Foundation

/// One running copy per bundle identifier: an exclusive advisory lock on a
/// file, released by the kernel when the process exits, so a crash never
/// leaves a stale lock behind.
public final class MakoshInstanceLock: Sendable {
    /// What a launch gets when it asks for its lock.
    public enum Acquisition: Sendable {
        case acquired(MakoshInstanceLock)
        /// Another process (or another open of the same file) holds the lock.
        case heldByOther
        /// The lock file could not be opened or locked at all; `code` is the `errno`.
        case failed(code: Int32)
    }

    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    /// A lock that cannot be created is reported as such, never as another copy.
    public static func acquire(at url: URL) -> Acquisition {
        let descriptor = openLockFile(at: url)
        guard descriptor >= 0 else { return .failed(code: errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            return code == EWOULDBLOCK ? .heldByOther : .failed(code: code)
        }
        return .acquired(MakoshInstanceLock(descriptor: descriptor))
    }

    /// Opens, creating it on demand with private permissions, a lock file for
    /// `flock`; -1 with `errno` set when it cannot be opened.
    static func openLockFile(at url: URL) -> Int32 {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    }

    /// `~/Library/Application Support/Makosh/<bundle id>.lock`.
    public static func defaultURL(bundleIdentifier: String) -> URL { lockURL(named: bundleIdentifier) }

    /// `~/Library/Application Support/Makosh/<name>.lock`.
    public static func lockURL(named name: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Makosh", isDirectory: true).appendingPathComponent(name + ".lock")
    }
}
