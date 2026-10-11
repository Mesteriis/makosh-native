import Foundation
import Darwin
import CryptoKit
import zlib

enum TelegramUploadArchiveIO {
    struct Source: Equatable, Sendable {
        let itemID: UUID
        let file: TelegramUploadFile
    }
    struct Member: Equatable, Sendable {
        let itemID: UUID
        let sourceName: String
        let entryName: String
        let byteCount: Int64
        let plaintextSHA256: String
    }
    struct Archive: Equatable, Sendable {
        let file: TelegramUploadFile
        let members: [Member]
    }
    static func prepare(_ sources: [Source], id: UUID = UUID(), progress: (@Sendable (Double) -> Void)? = nil) async throws -> Archive {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try write(sources, id: id, progress: progress) }
        return try await withTaskCancellationHandler {
            let archive = try await worker.value
            do { try Task.checkCancellation(); return archive }
            catch { try? TelegramUploadFileIO.discard(archive.file); throw error }
        } onCancel: { worker.cancel() }
    }

    // ZIP32/DEFLATE only. Original bytes are read from owned stages, never a
    // directory enumeration or display-name path. No upstream ZIP code is used.
    private static func write(_ sources: [Source], id: UUID, progress: (@Sendable (Double) -> Void)?) throws -> Archive {
        try Task.checkCancellation()
        guard sources.count <= TelegramUploadArchiveLimits.members,
              sources.allSatisfy({ $0.file.name.utf8.count <= TelegramUploadArchiveLimits.sourceNameBytes }) else {
            throw TelegramUploadFileError.tooLarge
        }
        guard id != TelegramPendingUploadDraft.zeroUUID, sources.count > 1, sources.count < Int(UInt16.max),
              Set(sources.map(\.itemID)).count == sources.count,
              Set(sources.map { $0.file.id }).count == sources.count,
              !sources.contains(where: { $0.itemID == id || $0.file.id == id }),
              sources.allSatisfy({ $0.itemID != TelegramPendingUploadDraft.zeroUUID &&
                  $0.file.id != TelegramPendingUploadDraft.zeroUUID &&
                  $0.file.mode == .file && $0.file.metadata == nil && $0.file.video == nil &&
                  $0.file.videoCover == nil && $0.file.pixelWidth == nil && $0.file.pixelHeight == nil &&
                  $0.file.name == telegramAttachmentName($0.file.name) }) else { throw TelegramUploadFileError.unavailable }
        let names = try entryNames(sources.map { $0.file.name })
        try TelegramUploadArchiveLimits.validateEntryNames(names)
        let maximum = TelegramUploadArchiveLimits.sourceBytes
        var total: Int64 = 0, snapshots: [stat] = []
        for source in sources {
            try Task.checkCancellation()
            guard source.file.size >= 0, source.file.size <= maximum - total else { throw TelegramUploadFileError.tooLarge }
            total += source.file.size
            try TelegramUploadFileIO.validateOwnedStage(source.file)
            var snapshot = stat()
            guard lstat(source.file.url.path, &snapshot) == 0, snapshot.st_mode & S_IFMT == S_IFREG,
                  snapshot.st_uid == getuid(), snapshot.st_mode & 0o777 == 0o600,
                  snapshot.st_size == source.file.size else { throw TelegramUploadFileError.unavailable }
            snapshots.append(snapshot)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("makosh-upload-" + id.uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw TelegramUploadFileError.stagingFailed }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        let partial = directory.appendingPathComponent("partial-" + id.uuidString)
        let url = directory.appendingPathComponent("payload-" + id.uuidString)
        var output = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw TelegramUploadFileError.stagingFailed }
        defer { if output >= 0 { Darwin.close(output) } }
        guard fchmod(output, 0o600) == 0 else { throw TelegramUploadFileError.stagingFailed }
        var position: Int64 = 0, processed: Int64 = 0, members: [Member] = [], central = Data()
        progress?(0)
        for index in sources.indices {
            try Task.checkCancellation()
            let source = sources[index], name = Data(names[index].utf8), offset = position
            let input = Darwin.open(source.file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard input >= 0 else { throw TelegramUploadFileError.unavailable }
            defer { Darwin.close(input) }
            var opened = stat()
            guard fstat(input, &opened) == 0, same(opened, snapshots[index]) else { throw TelegramUploadFileError.unavailable }
            try TelegramUploadVideoIO.validateSnapshot(source.file, fd: input, original: snapshots[index])
            let method: UInt16 = source.file.size == 0 ? 0 : 8
            let flags: UInt16 = 0x0800 | (method == 8 ? 2 : 0)
            let initial = localHeader(name: name, flags: flags, method: method, crc: 0, compressed: 0, size: 0)
            try emit(initial, fd: output, position: &position)
            let start = position
            let (crc, digest) = try compress(input: input, size: source.file.size, output: output, position: &position) { count in
                progress?(min(0.999, Double(processed + count) / Double(max(1, total))))
            }
            processed += source.file.size
            let compressed = UInt32(position - start), size = UInt32(source.file.size)
            try TelegramUploadVideoIO.validateSnapshot(source.file, fd: input, original: snapshots[index])
            try writeAll(localHeader(name: name, flags: flags, method: method, crc: crc, compressed: compressed, size: size),
                fd: output, offset: offset)
            var header = Data()
            header.zip32(0x02014b50); header.zip16(20); header.zip16(20)
            header.zip16(flags); header.zip16(method); header.zip16(0); header.zip16(0x21)
            header.zip32(crc); header.zip32(compressed); header.zip32(size)
            header.zip16(UInt16(name.count)); header.zip16(0); header.zip16(0)
            header.zip16(0); header.zip16(0); header.zip32(0); header.zip32(UInt32(offset)); header.append(name)
            central.append(header)
            members.append(.init(itemID: source.itemID, sourceName: source.file.name, entryName: names[index],
                byteCount: source.file.size, plaintextSHA256: digest))
        }
        // A source changed after its own compression must invalidate the whole
        // operation, rather than pairing an old ZIP member with newer raw bytes.
        for (source, snapshot) in zip(sources, snapshots) {
            try Task.checkCancellation()
            try TelegramUploadFileIO.validateOwnedStage(source.file)
            var current = stat()
            guard lstat(source.file.url.path, &current) == 0, same(current, snapshot) else { throw TelegramUploadFileError.unavailable }
        }
        let centralOffset = UInt32(position)
        try emit(central, fd: output, position: &position)
        var end = Data()
        end.zip32(0x06054b50); end.zip16(0); end.zip16(0)
        end.zip16(UInt16(members.count)); end.zip16(UInt16(members.count))
        end.zip32(UInt32(central.count)); end.zip32(centralOffset); end.zip16(0)
        try emit(end, fd: output, position: &position)
        try Task.checkCancellation()
        guard fsync(output) == 0 else { throw TelegramUploadFileError.stagingFailed }
        let closed = Darwin.close(output); output = -1
        guard closed == 0, Darwin.rename(partial.path, url.path) == 0 else { throw TelegramUploadFileError.stagingFailed }
        let file = TelegramUploadFile(id: id, name: "Telegram Archive.zip", size: position, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: url, directory: directory)
        try TelegramUploadFileIO.validateOwnedStage(file)
        try Task.checkCancellation()
        progress?(1)
        try Task.checkCancellation()
        success = true
        return Archive(file: file, members: members)
    }

    private static func entryNames(_ names: [String]) throws -> [String] {
        func key(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX")) }
        let reserved = Set(names.map(key))
        var used: Set<String> = [], result: [String] = []
        for name in names {
            try Task.checkCancellation()
            var candidate = name, number = 2
            while used.contains(key(candidate)) || (candidate != name && reserved.contains(key(candidate))) {
                let suffix = (name as NSString).pathExtension
                let base = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
                candidate = base + " (\(number))" + (suffix.isEmpty ? "" : "." + suffix)
                number += 1
                guard number <= names.count + 2 else { throw TelegramUploadFileError.unavailable }
            }
            guard !candidate.isEmpty, candidate.utf8.count < Int(UInt16.max), used.insert(key(candidate)).inserted else {
                throw TelegramUploadFileError.unavailable
            }
            result.append(candidate)
        }
        return result
    }

    private static func compress(input: Int32, size: Int64, output: Int32, position: inout Int64,
                                 progress: (Int64) -> Void) throws -> (UInt32, String) {
        var hash = SHA256(), checksum = crc32(0, nil, 0)
        guard size > 0 else { return (UInt32(checksum), hash.finalize().map { String(format: "%02x", $0) }.joined()) }
        // zlib retains a pointer to this stream; keep one address for its whole
        // lifetime instead of relying on separate Swift inout temporary scopes.
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer { stream.deinitialize(count: 1); stream.deallocate() }
        guard deflateInit2_(stream, Z_BEST_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TelegramUploadFileError.stagingFailed }
        var active = true
        defer { if active { deflateEnd(stream) } }
        var readPosition: Int64 = 0
        while readPosition < size {
            try Task.checkCancellation()
            let count = Int(min(65_536, size - readPosition))
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { bytes in
                var read = 0
                while read < count {
                    try Task.checkCancellation()
                    let actual = pread(input, bytes.baseAddress!.advanced(by: read), count - read, readPosition + Int64(read))
                    if actual < 0 && errno == EINTR { continue }
                    guard actual > 0 else { throw TelegramUploadFileError.unavailable }
                    read += actual
                }
            }
            hash.update(data: data)
            try data.withUnsafeBytes { bytes in
                checksum = crc32(checksum, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(count))
                stream.pointee.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
                stream.pointee.avail_in = uInt(count)
                defer { stream.pointee.next_in = nil }
                while stream.pointee.avail_in > 0 { _ = try deflateChunk(stream, flush: Z_NO_FLUSH, output: output, position: &position) }
            }
            readPosition += Int64(count)
            progress(readPosition)
        }
        while try deflateChunk(stream, flush: Z_FINISH, output: output, position: &position) != Z_STREAM_END {}
        let ended = deflateEnd(stream); active = false
        guard ended == Z_OK else { throw TelegramUploadFileError.stagingFailed }
        return (UInt32(checksum), hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func deflateChunk(_ stream: UnsafeMutablePointer<z_stream>, flush: Int32, output: Int32, position: inout Int64) throws -> Int32 {
        try Task.checkCancellation()
        var buffer = Data(count: 65_536)
        let before = stream.pointee.avail_in
        return try buffer.withUnsafeMutableBytes { bytes in
            stream.pointee.next_out = bytes.bindMemory(to: Bytef.self).baseAddress; stream.pointee.avail_out = uInt(bytes.count)
            defer { stream.pointee.next_out = nil }
            let status = deflate(stream, flush), count = bytes.count - Int(stream.pointee.avail_out)
            guard status == Z_OK || (flush == Z_FINISH && status == Z_STREAM_END),
                  count > 0 || stream.pointee.avail_in < before else { throw TelegramUploadFileError.stagingFailed }
            guard position < Int64(UInt32.max) - Int64(count) else { throw TelegramUploadFileError.tooLarge }
            try writeAll(Data(bytes.prefix(count)), fd: output, offset: position)
            position += Int64(count)
            return status
        }
    }

    private static func localHeader(name: Data, flags: UInt16, method: UInt16, crc: UInt32, compressed: UInt32, size: UInt32) -> Data {
        var data = Data()
        data.zip32(0x04034b50); data.zip16(20); data.zip16(flags); data.zip16(method)
        data.zip16(0); data.zip16(0x21); data.zip32(crc); data.zip32(compressed); data.zip32(size)
        data.zip16(UInt16(name.count)); data.zip16(0); data.append(name)
        return data
    }

    private static func emit(_ data: Data, fd: Int32, position: inout Int64) throws {
        guard position < Int64(UInt32.max) - Int64(data.count) else { throw TelegramUploadFileError.tooLarge }
        try writeAll(data, fd: fd, offset: position); position += Int64(data.count)
    }
    private static func writeAll(_ data: Data, fd: Int32, offset: Int64) throws {
        try data.withUnsafeBytes { bytes in
            var position = 0
            while position < data.count {
                try Task.checkCancellation()
                let count = pwrite(fd, bytes.baseAddress!.advanced(by: position), min(65_536, data.count - position), offset + Int64(position))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TelegramUploadFileError.stagingFailed }
                position += count
            }
        }
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid &&
            a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
            a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec &&
            a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}

// Product limits bound metadata independently of raw bytes and ZIP32's much
// wider fields. Count/source-name checks precede normalization; allocated-name
// and central-directory checks precede source IO and output creation.
enum TelegramUploadArchiveLimits {
    static let members = 1024
    static let sourceNameBytes = 1024
    static let entryNameBytes = 1040
    static let centralBytes = 1024 * 1024
    static let sourceBytes: Int64 = 1500 * 1024 * 1024

    static func validateEntryNames(_ names: [String]) throws {
        guard names.count <= members else { throw TelegramUploadFileError.tooLarge }
        var total = 0
        for name in names {
            let count = name.utf8.count
            guard count <= entryNameBytes, count + 46 <= centralBytes - total else {
                throw TelegramUploadFileError.tooLarge
            }
            total += count + 46
        }
    }
}

private extension Data {
    mutating func zip16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func zip32(_ value: UInt32) { zip16(UInt16(truncatingIfNeeded: value)); zip16(UInt16(truncatingIfNeeded: value >> 16)) }
}
