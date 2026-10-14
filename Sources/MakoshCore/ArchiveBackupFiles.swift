import Foundation
import CryptoKit
import Darwin

/// A selected path is traversed without following any symbolic link.
final class ArchiveBackupDirectory {
    let url: URL
    let fd: Int32
    init(_ url: URL, requireTrustedParents: Bool = false) throws {
        guard url.isFileURL, url.host?.isEmpty != false, url.path.hasPrefix("/"),
              url.path.utf8.count <= 4096, !url.path.utf8.contains(0) else { throw ArchiveBackupError.invalid }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw ArchiveBackupError.invalid }
        do {
            if requireTrustedParents { try ArchiveBackupPermissions.trustedDirectory(current) }
            for component in url.pathComponents where component != "/" {
                try Self.name(component)
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ArchiveBackupError.invalid }
                Darwin.close(current); current = next
                if requireTrustedParents { try ArchiveBackupPermissions.trustedDirectory(current) }
            }
        } catch { Darwin.close(current); throw error }
        self.url = url; fd = current
    }
    private init(url: URL, fd: Int32) { self.url = url; self.fd = fd }
    deinit { Darwin.close(fd) }
    static func temporaryBase() throws -> URL {
        // Foundation preserves the system /var alias on this host. Resolve only
        // the OS-provided scratch base; user-selected paths remain strict.
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw ArchiveBackupError.invalid }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
    static func name(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255,
              !name.utf8.contains(0), !name.contains("/") else { throw ArchiveBackupError.invalid }
    }
    func createDirectory(_ name: String) throws -> ArchiveBackupDirectory {
        try Self.name(name)
        try ArchiveBackupPermissions.trustedDirectory(fd)
        guard mkdirat(fd, name, 0o700) == 0 else { throw ArchiveBackupError.conflict }
        let child = try directory(name)
        try ArchiveBackupPermissions.makePrivate(child.fd, mode: 0o700)
        return child
    }
    func directory(_ name: String) throws -> ArchiveBackupDirectory {
        try Self.name(name)
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw ArchiveBackupError.invalid }
        return .init(url: url.appendingPathComponent(name, isDirectory: true), fd: child)
    }
    func file(_ name: String, create: Bool = false) throws -> ArchiveBackupFile {
        try Self.name(name)
        let flags = create ? O_WRONLY | O_CREAT | O_EXCL : O_RDONLY | O_NONBLOCK
        let child = openat(fd, name, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard child >= 0 else { throw create ? ArchiveBackupError.conflict : ArchiveBackupError.invalid }
        if create {
            do { try ArchiveBackupPermissions.makePrivate(child, mode: 0o600) }
            catch { Darwin.close(child); unlinkat(fd, name, 0); throw error }
        }
        return try ArchiveBackupFile(fd: child)
    }
    func names() throws -> Set<String> {
        let copied = dup(fd)
        guard copied >= 0, let stream = fdopendir(copied) else {
            if copied >= 0 { Darwin.close(copied) }; throw ArchiveBackupError.invalid
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var result = Set<String>()
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
            if name == "." || name == ".." { continue }
            try Self.name(name)
            guard result.count < 101_030, result.insert(name).inserted else { throw ArchiveBackupError.invalid }
            errno = 0
        }
        guard errno == 0 else { throw ArchiveBackupError.invalid }
        return result
    }
    func sync() throws { guard fsync(fd) == 0 else { throw ArchiveBackupError.invalid } }
    func requireAbsent(_ name: String) throws {
        try Self.name(name)
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 else { throw ArchiveBackupError.conflict }
        guard errno == ENOENT else { throw ArchiveBackupError.invalid }
    }
    func publish(_ stagingName: String, as destinationName: String, expected: ArchiveBackupDirectory) throws {
        try Self.name(stagingName); try Self.name(destinationName)
        var entry = stat(), held = stat()
        guard fstatat(fd, stagingName, &entry, AT_SYMLINK_NOFOLLOW) == 0, fstat(expected.fd, &held) == 0,
              entry.st_mode & S_IFMT == S_IFDIR, entry.st_dev == held.st_dev, entry.st_ino == held.st_ino else { throw ArchiveBackupError.changed }
        guard renameatx_np(fd, stagingName, fd, destinationName, UInt32(RENAME_EXCL)) == 0 else { throw ArchiveBackupError.conflict }
        try sync()
    }
}

final class ArchiveBackupFile {
    let fd: Int32
    private let original: stat
    init(fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            Darwin.close(fd); throw ArchiveBackupError.invalid
        }
        self.fd = fd; original = info
    }
    deinit { Darwin.close(fd) }
    var byteCount: Int64 { original.st_size }
    func rewind() throws { guard lseek(fd, 0, SEEK_SET) == 0 else { throw ArchiveBackupError.invalid } }
    func stable() throws {
        var final = stat()
        guard fstat(fd, &final) == 0, final.st_dev == original.st_dev, final.st_ino == original.st_ino,
              final.st_size == original.st_size,
              final.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec, final.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else { throw ArchiveBackupError.integrity }
    }
    func read(_ count: Int) throws -> Data {
        guard (0...8 * 1024 * 1024).contains(count) else { throw ArchiveBackupError.invalid }
        var data = Data(count: count), received = 0
        try data.withUnsafeMutableBytes { raw in
            while received < count {
                let n = Darwin.read(fd, raw.baseAddress!.advanced(by: received), count - received)
                if n < 0 && errno == EINTR { continue }
                guard n >= 0 else { throw ArchiveBackupError.invalid }
                if n == 0 { break }; received += n
            }
        }
        data.count = received; return data
    }
    func readExactly(_ count: Int) throws -> Data {
        let data = try read(count); guard data.count == count else { throw ArchiveBackupError.integrity }; return data
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ArchiveBackupError.invalid }; offset += n
            }
        }
    }
    func sync() throws { guard fsync(fd) == 0 else { throw ArchiveBackupError.invalid } }
    func boundedData(maximum: Int) throws -> Data {
        guard byteCount <= maximum else { throw ArchiveBackupError.invalid }
        let result = try readExactly(Int(byteCount)); try stable(); return result
    }
    func sha256(expectedCount: Int64) throws -> String {
        guard byteCount == expectedCount else { throw ArchiveBackupError.integrity }
        var remaining = expectedCount, hash = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try readExactly(Int(min(remaining, 1024 * 1024)))
            hash.update(data: data); remaining -= Int64(data.count)
        }
        guard try read(1).isEmpty else { throw ArchiveBackupError.integrity }; try stable()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    @discardableResult func copy(to destination: ArchiveBackupFile, expectedCount: Int64, expectedHash: String? = nil) throws -> String {
        guard byteCount == expectedCount else { throw ArchiveBackupError.integrity }
        var remaining = expectedCount, hash = SHA256()
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try readExactly(Int(min(remaining, 1024 * 1024)))
            hash.update(data: data); try destination.write(data); remaining -= Int64(data.count)
        }
        guard try read(1).isEmpty else { throw ArchiveBackupError.integrity }
        try stable(); try destination.sync()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard expectedHash == nil || expectedHash == digest else { throw ArchiveBackupError.integrity }
        return digest
    }
}

final class ArchiveBackupWorkspace {
    let directory: ArchiveBackupDirectory
    init() throws {
        let base = try ArchiveBackupDirectory(ArchiveBackupDirectory.temporaryBase(), requireTrustedParents: true)
        directory = try base.createDirectory("makosh-archive-backup-\(UUID().uuidString.lowercased())")
    }
    deinit { try? FileManager.default.removeItem(at: directory.url) }
}
