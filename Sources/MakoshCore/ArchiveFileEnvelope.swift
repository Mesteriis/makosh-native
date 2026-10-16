import Foundation
import CryptoKit
import Darwin

public struct ArchiveFileEnvelopeReceipt: Sendable, Equatable {
    public let byteCount: Int64
    public let sha256: String
    public let plaintextByteCount: Int64
    public let plaintextSHA256: String
}
public enum ArchiveFileEnvelopeError: Error, LocalizedError {
    case invalid, unavailable, integrity, output
    public var errorDescription: String? { "Не удалось проверить или подготовить файл архива." }
}

private let envelopeChunk = 1024 * 1024
private let envelopeCap: Int64 = 4 * 1024 * 1024 * 1024
private func integer(_ value: UInt64) -> Data {
    var big = value.bigEndian
    return withUnsafeBytes(of: &big) { Data($0) }
}
private func number(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }
private func header(_ id: UUID, _ size: Int64) -> Data {
    Data("MKFILE01".utf8) + Data(id.uuidString.lowercased().utf8) + integer(UInt64(size)) + integer(UInt64(envelopeChunk))
}
private func derived(_ key: Data, _ id: UUID) throws -> SymmetricKey {
    guard key.count == 32 else { throw ArchiveFileEnvelopeError.invalid }
    return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: Data(id.uuidString.lowercased().utf8), info: Data("makosh-s3-file-envelope-v1".utf8), outputByteCount: 32)
}
private func sourceFD(_ url: URL, size: Int64? = nil) throws -> (Int32, stat) {
    guard url.isFileURL, !url.path.utf8.contains(0) else { throw ArchiveFileEnvelopeError.invalid }
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw ArchiveFileEnvelopeError.unavailable }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
          info.st_size >= 0, size == nil || info.st_size == size else {
        Darwin.close(fd); throw ArchiveFileEnvelopeError.unavailable
    }
    return (fd, info)
}
private func outputFD(_ url: URL) throws -> Int32 {
    guard url.isFileURL, !url.path.utf8.contains(0) else { throw ArchiveFileEnvelopeError.output }
    let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ArchiveFileEnvelopeError.output }
    guard fchmod(fd, 0o600) == 0 else { Darwin.close(fd); unlink(url.path); throw ArchiveFileEnvelopeError.output }
    return fd
}
private func readExactly(_ fd: Int32, _ count: Int, at position: Int64? = nil) throws -> Data {
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { bytes in
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let n = position.map { Darwin.pread(fd, bytes.baseAddress!.advanced(by: offset),count-offset,off_t($0)+off_t(offset)) }
                ?? Darwin.read(fd, bytes.baseAddress!.advanced(by: offset), count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ArchiveFileEnvelopeError.integrity }
            offset += n
        }
    }
    return data
}
private func writeExactly(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw ArchiveFileEnvelopeError.output }
            offset += n
        }
    }
}
private func digest(_ hash: SHA256) -> String { hash.finalize().map { String(format: "%02x", $0) }.joined() }
private func stable(_ fd: Int32, _ original: stat) throws {
    var final = stat()
    guard fstat(fd, &final) == 0, final.st_dev == original.st_dev, final.st_ino == original.st_ino,
          final.st_size == original.st_size,
          final.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
          final.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec else { throw ArchiveFileEnvelopeError.unavailable }
    // Unlink changes ctime/link count; the open FD intentionally remains a valid capture.
}

public final class ArchiveFileCapture: @unchecked Sendable {
    private let fd: Int32
    private let original: stat
    private let lock = NSLock()
    private var used = false
    public init(file: URL, byteCount: Int64) throws {
        guard byteCount >= 0, byteCount <= envelopeCap else { throw ArchiveFileEnvelopeError.invalid }
        (fd, original) = try sourceFD(file, size: byteCount)
    }
    private init(fd: Int32,original: stat) { self.fd = fd; self.original = original }
    /// A retry gets its own cursor while retaining the same frozen inode, even
    /// when the original cache path has already been unlinked.
    public func duplicate() throws -> ArchiveFileCapture {
        lock.lock(); defer { lock.unlock() }
        try stable(fd,original)
        let copied = fcntl(fd,F_DUPFD_CLOEXEC,0)
        guard copied >= 0 else { throw ArchiveFileEnvelopeError.unavailable }
        return ArchiveFileCapture(fd: copied,original: original)
    }
    deinit { Darwin.close(fd) }
    /// Content identity for idempotent preparation retries. Reads the frozen
    /// inode in bounded chunks without consuming its encryption capability.
    public func plaintextSHA256() throws -> String {
        try Task.checkCancellation()
        lock.lock(); defer { lock.unlock() }
        try stable(fd, original)
        var hash = SHA256(), offset: Int64 = 0
        while offset < original.st_size {
            try Task.checkCancellation()
            let count = Int(min(Int64(envelopeChunk), original.st_size - offset))
            hash.update(data: try readExactly(fd, count, at: offset))
            offset += Int64(count)
        }
        try stable(fd, original)
        return digest(hash)
    }
    public func seal(to destination: URL, key: Data, objectID: UUID) throws -> ArchiveFileEnvelopeReceipt {
        try Task.checkCancellation()
        lock.lock(); defer { lock.unlock() }
        guard !used else { throw ArchiveFileEnvelopeError.invalid }; used = true
        let key = try derived(key, objectID)
        try stable(fd, original)
        let output = try outputFD(destination)
        var success = false
        defer { Darwin.close(output); if !success { unlink(destination.path) } }
        let head = header(objectID, original.st_size)
        var encryptedHash = SHA256(), plaintextHash = SHA256(), written: Int64 = 0
        func emit(_ data: Data) throws { try writeExactly(output,data); encryptedHash.update(data: data); written += Int64(data.count) }
        try emit(head)
        let chunks = max(1, (original.st_size + Int64(envelopeChunk) - 1) / Int64(envelopeChunk))
        for index in 0..<chunks {
            try Task.checkCancellation()
            let count = Int(min(Int64(envelopeChunk), original.st_size - index * Int64(envelopeChunk)))
            let bytes = try readExactly(fd,count,at: index * Int64(envelopeChunk)); plaintextHash.update(data: bytes)
            let aad = head + integer(UInt64(index)) + integer(UInt64(chunks)) + integer(UInt64(count))
            let sealed: Data
            do {
                guard let combined = try AES.GCM.seal(bytes, using: key, authenticating: aad).combined else { throw ArchiveFileEnvelopeError.integrity }
                sealed = combined
            } catch { throw ArchiveFileEnvelopeError.integrity }
            try emit(integer(UInt64(sealed.count))); try emit(sealed)
        }
        try stable(fd,original)
        try Task.checkCancellation()
        guard fsync(output) == 0 else { throw ArchiveFileEnvelopeError.output }
        success = true
        return ArchiveFileEnvelopeReceipt(byteCount: written, sha256: digest(encryptedHash), plaintextByteCount: original.st_size, plaintextSHA256: digest(plaintextHash))
    }
}

public enum ArchiveFileEnvelope {
    public static func open(file: URL, to destination: URL, key: Data, objectID: UUID, plaintextByteCount: Int64) throws -> String {
        try Task.checkCancellation()
        guard plaintextByteCount >= 0, plaintextByteCount <= envelopeCap else { throw ArchiveFileEnvelopeError.invalid }
        let key = try derived(key,objectID)
        let (input, original) = try sourceFD(file)
        defer { Darwin.close(input) }
        let head = header(objectID,plaintextByteCount)
        guard try readExactly(input,head.count) == head else { throw ArchiveFileEnvelopeError.integrity }
        let output = try outputFD(destination)
        var success = false
        defer { Darwin.close(output); if !success { unlink(destination.path) } }
        var hash = SHA256()
        let chunks = max(1, (plaintextByteCount + Int64(envelopeChunk) - 1) / Int64(envelopeChunk))
        for index in 0..<chunks {
            try Task.checkCancellation()
            let count = Int(min(Int64(envelopeChunk), plaintextByteCount - index * Int64(envelopeChunk)))
            let length = number(try readExactly(input,8))
            guard length == UInt64(count + 28) else { throw ArchiveFileEnvelopeError.integrity }
            let sealed = try readExactly(input,Int(length))
            let aad = head + integer(UInt64(index)) + integer(UInt64(chunks)) + integer(UInt64(count))
            let plain: Data
            do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad) }
            catch { throw ArchiveFileEnvelopeError.integrity }
            guard plain.count == count else { throw ArchiveFileEnvelopeError.integrity }
            try writeExactly(output,plain); hash.update(data: plain)
        }
        var extra: UInt8 = 0
        guard Darwin.read(input,&extra,1) == 0 else { throw ArchiveFileEnvelopeError.integrity }
        try stable(input,original)
        try Task.checkCancellation()
        guard fsync(output) == 0 else { throw ArchiveFileEnvelopeError.output }
        success = true
        return digest(hash)
    }
}
