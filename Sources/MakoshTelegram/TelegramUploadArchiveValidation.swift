import Foundation
import Darwin
import CryptoKit
import zlib

enum TelegramUploadArchiveValidation {
    static func validate(_ archive: TelegramUploadArchiveIO.Archive,
                         sources: [TelegramUploadArchiveIO.Source]) async throws {
        try Task.checkCancellation()
        guard sources.count <= TelegramUploadArchiveLimits.members,
              archive.members.count <= TelegramUploadArchiveLimits.members,
              sources.allSatisfy({ $0.file.name.utf8.count <= TelegramUploadArchiveLimits.sourceNameBytes }) else {
            throw TelegramUploadFileError.tooLarge
        }
        try TelegramUploadArchiveLimits.validateEntryNames(archive.members.map(\.entryName))
        let worker = Task.detached(priority: .utility) { try inspect(archive, sources: sources) }
        try await withTaskCancellationHandler {
            try await worker.value
            try Task.checkCancellation()
        } onCancel: { worker.cancel() }
    }

    // Only the independently authored writer's ZIP32 profile is admitted.
    // Allocated names are durable input; validation never reruns the allocator.
    private static func inspect(_ archive: TelegramUploadArchiveIO.Archive,
                                sources: [TelegramUploadArchiveIO.Source]) throws {
        try Task.checkCancellation()
        guard sources.count > 1, sources.count < Int(UInt16.max), archive.members.count == sources.count,
              archive.file.id != TelegramPendingUploadDraft.zeroUUID,
              archive.file.name == "Telegram Archive.zip", plain(archive.file),
              archive.file.size >= 22, archive.file.size < Int64(UInt32.max),
              Set(sources.map(\.itemID)).count == sources.count,
              Set(sources.map { $0.file.id }).count == sources.count,
              !sources.contains(where: { $0.itemID == archive.file.id || $0.file.id == archive.file.id }) else {
            throw TelegramUploadFileError.unavailable
        }
        let maximum = TelegramUploadArchiveLimits.sourceBytes
        var total: Int64 = 0, names: Set<String> = [], snapshots: [stat] = []
        for (source, member) in zip(sources, archive.members) {
            try Task.checkCancellation()
            guard source.itemID != TelegramPendingUploadDraft.zeroUUID,
                  source.file.id != TelegramPendingUploadDraft.zeroUUID, plain(source.file),
                  source.file.name == telegramAttachmentName(source.file.name),
                  source.file.size >= 0, source.file.size <= maximum - total else {
                throw TelegramUploadFileError.unavailable
            }
            total += source.file.size
            guard member.itemID == source.itemID, member.sourceName.utf8.elementsEqual(source.file.name.utf8),
                  member.byteCount == source.file.size, validDigest(member.plaintextSHA256),
                  safeName(member.entryName),
                  names.insert(member.entryName.precomposedStringWithCanonicalMapping
                    .lowercased(with: Locale(identifier: "en_US_POSIX"))).inserted else {
                throw TelegramUploadFileError.unavailable
            }
            let opened = try open(source.file)
            snapshots.append(opened.original)
            opened.close()
        }
        let zip = try open(archive.file)
        defer { zip.close() }
        let endOffset = archive.file.size - 22
        let end = try read(zip.fd, offset: endOffset, count: 22)
        guard u32(end, 0) == 0x06054b50, u16(end, 4) == 0, u16(end, 6) == 0,
              u16(end, 8) == UInt16(sources.count), u16(end, 10) == UInt16(sources.count),
              u16(end, 20) == 0 else { throw TelegramUploadFileError.unavailable }
        let centralStart = Int64(u32(end, 16)), centralSize = Int64(u32(end, 12))
        guard centralStart > 0, centralStart <= endOffset, centralSize == endOffset - centralStart else {
            throw TelegramUploadFileError.unavailable
        }
        var localPosition: Int64 = 0, centralPosition = centralStart
        for index in sources.indices {
            try Task.checkCancellation()
            let source = sources[index], member = archive.members[index], name = Data(member.entryName.utf8)
            guard centralPosition <= endOffset - 46 - Int64(name.count) else { throw TelegramUploadFileError.unavailable }
            let central = try read(zip.fd, offset: centralPosition, count: 46)
            let method: UInt16 = member.byteCount == 0 ? 0 : 8
            let flags: UInt16 = method == 0 ? 0x800 : 0x802
            let crc = u32(central, 16), compressed = Int64(u32(central, 20))
            guard u32(central, 0) == 0x02014b50, u16(central, 4) == 20, u16(central, 6) == 20,
                  u16(central, 8) == flags, u16(central, 10) == method,
                  u16(central, 12) == 0, u16(central, 14) == 0x21,
                  Int64(u32(central, 24)) == member.byteCount,
                  u16(central, 28) == UInt16(name.count), u16(central, 30) == 0,
                  u16(central, 32) == 0, u16(central, 34) == 0, u16(central, 36) == 0,
                  u32(central, 38) == 0, Int64(u32(central, 42)) == localPosition,
                  try read(zip.fd, offset: centralPosition + 46, count: name.count) == name,
                  (method == 0 ? compressed == 0 && crc == 0 : compressed > 0),
                  localPosition <= centralStart - 30 - Int64(name.count) else {
                throw TelegramUploadFileError.unavailable
            }
            let local = try read(zip.fd, offset: localPosition, count: 30)
            guard u32(local, 0) == 0x04034b50, u16(local, 4) == 20,
                  u16(local, 6) == flags, u16(local, 8) == method,
                  u16(local, 10) == 0, u16(local, 12) == 0x21,
                  u32(local, 14) == crc, Int64(u32(local, 18)) == compressed,
                  Int64(u32(local, 22)) == member.byteCount, u16(local, 26) == UInt16(name.count),
                  u16(local, 28) == 0,
                  try read(zip.fd, offset: localPosition + 30, count: name.count) == name else {
                throw TelegramUploadFileError.unavailable
            }
            let payload = localPosition + 30 + Int64(name.count)
            guard compressed <= centralStart - payload else { throw TelegramUploadFileError.unavailable }
            let raw = try open(source.file)
            defer { raw.close() }
            guard same(raw.original, snapshots[index]) else { throw TelegramUploadFileError.unavailable }
            if method == 0 {
                guard member.plaintextSHA256 == digest(SHA256().finalize()) else { throw TelegramUploadFileError.unavailable }
            } else {
                try inflateMember(zipFD: zip.fd, offset: payload, compressed: compressed,
                                  rawFD: raw.fd, member: member, expectedCRC: crc)
            }
            try raw.validate()
            localPosition = payload + compressed
            centralPosition += 46 + Int64(name.count)
        }
        guard localPosition == centralStart, centralPosition == endOffset else { throw TelegramUploadFileError.unavailable }
        // A previously checked member must not change while later members are read.
        for (source, snapshot) in Swift.zip(sources, snapshots) {
            try Task.checkCancellation()
            let current = try open(source.file)
            defer { current.close() }
            guard same(current.original, snapshot) else { throw TelegramUploadFileError.unavailable }
            try current.validate()
        }
        try zip.validate()
        try Task.checkCancellation()
    }

    private static func inflateMember(zipFD: Int32, offset: Int64, compressed: Int64,
                                      rawFD: Int32, member: TelegramUploadArchiveIO.Member,
                                      expectedCRC: UInt32) throws {
        // zlib retains the stream address. Allocate it once through inflateEnd.
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        defer { stream.deinitialize(count: 1); stream.deallocate() }
        guard inflateInit2_(stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw TelegramUploadFileError.unavailable
        }
        var active = true
        defer { if active { inflateEnd(stream) } }
        var inputPosition: Int64 = 0, outputPosition: Int64 = 0
        var decodedHash = SHA256(), rawHash = SHA256(), checksum = crc32(0, nil, 0), ended = false
        while inputPosition < compressed && !ended {
            try Task.checkCancellation()
            let input = try read(zipFD, offset: offset + inputPosition, count: Int(min(65_536, compressed - inputPosition)))
            try input.withUnsafeBytes { bytes in
                stream.pointee.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
                stream.pointee.avail_in = uInt(bytes.count)
                defer { stream.pointee.next_in = nil }
                repeat {
                    try Task.checkCancellation()
                    var output = Data(count: 65_536)
                    let before = stream.pointee.avail_in
                    let (status, produced) = output.withUnsafeMutableBytes { buffer -> (Int32, Int) in
                        stream.pointee.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                        stream.pointee.avail_out = uInt(buffer.count)
                        defer { stream.pointee.next_out = nil }
                        let status = inflate(stream, Z_NO_FLUSH)
                        return (status, buffer.count - Int(stream.pointee.avail_out))
                    }
                    guard status == Z_OK || status == Z_STREAM_END,
                          produced > 0 || stream.pointee.avail_in < before,
                          Int64(produced) <= member.byteCount - outputPosition else {
                        throw TelegramUploadFileError.unavailable
                    }
                    if produced > 0 {
                        output.count = produced
                        let raw = try read(rawFD, offset: outputPosition, count: produced)
                        decodedHash.update(data: output); rawHash.update(data: raw)
                        output.withUnsafeBytes { buffer in
                            checksum = crc32(checksum, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count))
                        }
                        outputPosition += Int64(produced)
                    }
                    if status == Z_STREAM_END {
                        guard stream.pointee.avail_in == 0, inputPosition + Int64(input.count) == compressed else {
                            throw TelegramUploadFileError.unavailable
                        }
                        ended = true
                        break
                    }
                } while stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0
            }
            inputPosition += Int64(input.count)
        }
        guard ended, outputPosition == member.byteCount, UInt32(checksum) == expectedCRC,
              digest(decodedHash.finalize()) == member.plaintextSHA256,
              digest(rawHash.finalize()) == member.plaintextSHA256 else { throw TelegramUploadFileError.unavailable }
        let status = inflateEnd(stream); active = false
        guard status == Z_OK else { throw TelegramUploadFileError.unavailable }
    }

    private struct Opened {
        let file: TelegramUploadFile
        let fd: Int32
        let directoryFD: Int32
        let original: stat
        let directory: stat

        func close() { Darwin.close(fd); Darwin.close(directoryFD) }

        func validate() throws {
            var held = stat(), path = stat(), directoryPath = stat()
            guard fstat(fd, &held) == 0, lstat(file.url.path, &path) == 0,
                  lstat(file.directory.path, &directoryPath) == 0,
                  same(held, original), same(path, original),
                  directoryPath.st_dev == directory.st_dev, directoryPath.st_ino == directory.st_ino,
                  directoryPath.st_mode == directory.st_mode, directoryPath.st_uid == directory.st_uid else {
                throw TelegramUploadFileError.unavailable
            }
        }
    }

    private static func open(_ file: TelegramUploadFile) throws -> Opened {
        try Task.checkCancellation()
        try TelegramUploadFileIO.validateOwnedStage(file)
        let directoryFD = Darwin.open(file.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard directoryFD >= 0 else { throw TelegramUploadFileError.unavailable }
        var success = false, fd: Int32 = -1
        defer { if !success { if fd >= 0 { Darwin.close(fd) }; Darwin.close(directoryFD) } }
        var directory = stat(), original = stat()
        guard fstat(directoryFD, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == getuid(), directory.st_mode & 0o777 == 0o700 else { throw TelegramUploadFileError.unavailable }
        fd = openat(directoryFD, "payload-" + file.id.uuidString, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0, fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == getuid(), original.st_mode & 0o777 == 0o600,
              original.st_size == file.size else { throw TelegramUploadFileError.unavailable }
        let result = Opened(file: file, fd: fd, directoryFD: directoryFD, original: original, directory: directory)
        try result.validate()
        success = true
        return result
    }

    private static func read(_ fd: Int32, offset: Int64, count: Int) throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, count <= 65_536 else { throw TelegramUploadFileError.unavailable }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var position = 0
            while position < count {
                try Task.checkCancellation()
                let actual = pread(fd, bytes.baseAddress!.advanced(by: position), count - position, offset + Int64(position))
                if actual < 0 && errno == EINTR { continue }
                guard actual > 0 else { throw TelegramUploadFileError.unavailable }
                position += actual
            }
        }
        return data
    }

    private static func plain(_ file: TelegramUploadFile) -> Bool {
        file.mode == .file && file.metadata == nil && file.video == nil && file.videoCover == nil &&
            file.pixelWidth == nil && file.pixelHeight == nil
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count < Int(UInt16.max) &&
            !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || "/\\:".unicodeScalars.contains($0) }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func digest(_ value: SHA256.Digest) -> String { value.map { String(format: "%02x", $0) }.joined() }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(u16(data, offset)) | UInt32(u16(data, offset + 2)) << 16
    }

    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid &&
            a.st_nlink == b.st_nlink && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
