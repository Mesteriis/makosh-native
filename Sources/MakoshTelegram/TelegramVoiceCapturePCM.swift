import Foundation
import AVFoundation
import AudioToolbox
import Darwin

public enum TelegramVoiceCaptureError: Error, Equatable {
    case permissionDenied, unavailable, invalidRecording, invalidState
}

final class TelegramVoiceCapturePCM: @unchecked Sendable {
    private static let maximumFrames: Int64 = 28_800_000
    private static let maximumOverhead: Int64 = 1_048_576
    let directory: URL
    let url: URL
    private let directoryFD: Int32
    private let directoryIdentity: stat
    private let lock = NSLock()
    private var fileFD: Int32
    private var snapshot: stat?
    private var consumed = false
    private var discarded = false

    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("makosh-voice-" + UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("recording.caf")
        guard mkdir(directory.path, 0o700) == 0 else { throw TelegramVoiceCaptureError.unavailable }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else {
            rmdir(directory.path)
            throw TelegramVoiceCaptureError.unavailable
        }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            Darwin.close(parent); rmdir(directory.path)
            throw TelegramVoiceCaptureError.unavailable
        }
        let file = openat(parent, "recording.caf", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0, fchmod(file, 0o600) == 0 else {
            if file >= 0 { Darwin.close(file) }
            unlinkat(parent, "recording.caf", 0); Darwin.close(parent); rmdir(directory.path)
            throw TelegramVoiceCaptureError.unavailable
        }
        directoryFD = parent; directoryIdentity = info; fileFD = file
    }

    deinit { discard(); Darwin.close(fileFD); Darwin.close(directoryFD) }

    /// Called after the native writer prepares its file, before microphone capture starts.
    func secureForRecording() throws {
        try lock.withLock {
            guard !discarded, !consumed, snapshot == nil else { throw TelegramVoiceCaptureError.invalidState }
            try validateDirectory()
            let fd = openat(directoryFD, "recording.caf", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw TelegramVoiceCaptureError.unavailable }
            var keep = false
            defer { if !keep { Darwin.close(fd) } }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_nlink == 1, fchmod(fd, 0o600) == 0 else {
                throw TelegramVoiceCaptureError.unavailable
            }
            Darwin.close(fileFD); fileFD = fd; keep = true
        }
    }

    /// Freeze the final closed CAF. A later path, mode, size or timestamp change refuses consumption.
    func seal() throws {
        try lock.withLock {
            guard !discarded, !consumed, snapshot == nil else { throw TelegramVoiceCaptureError.invalidState }
            try validateDirectory()
            var info = stat(), path = stat()
            guard fstat(fileFD, &info) == 0, lstat(url.path, &path) == 0,
                  path.st_dev == info.st_dev, path.st_ino == info.st_ino,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
                  fchmod(fileFD, 0o600) == 0, fstat(fileFD, &info) == 0 else {
                throw TelegramVoiceCaptureError.unavailable
            }
            snapshot = info
        }
    }

    func consume() async throws -> [Int16] {
        defer { discard() }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try self.readSealed() }
        let pcm = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return pcm
    }

    func discard() {
        lock.withLock {
            guard !discarded else { return }
            discarded = true
            var held = stat()
            if fstat(directoryFD, &held) == 0, held.st_uid == getuid(),
               held.st_dev == directoryIdentity.st_dev, held.st_ino == directoryIdentity.st_ino {
                // A restrictive mode change must not strand our own plaintext capture during refusal.
                fchmod(directoryFD, 0o700)
            }
            // Relative unlink never follows a substituted file symlink. The directory fd stays held
            // through a concurrent read; it is closed only when the last owner releases this object.
            unlinkat(directoryFD, "recording.caf", 0)
            var path = stat()
            if lstat(directory.path, &path) == 0, path.st_mode & S_IFMT == S_IFDIR,
               path.st_dev == directoryIdentity.st_dev, path.st_ino == directoryIdentity.st_ino {
                rmdir(directory.path)
            }
        }
    }

    private func readSealed() throws -> [Int16] {
        let original: stat = try lock.withLock {
            guard !discarded, !consumed, let snapshot else { throw TelegramVoiceCaptureError.invalidState }
            consumed = true
            return snapshot
        }
        do {
            try Task.checkCancellation()
            try validateSnapshot(original)
            guard original.st_size > 0, original.st_size <= Self.maximumFrames * 2 + Self.maximumOverhead else {
                throw TelegramVoiceCaptureError.invalidRecording
            }
            let dataBytes = try validateCAF(size: original.st_size)
            // Opening our held descriptor avoids a second path lookup by the native reader.
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: "/dev/fd/\(fileFD)"),
                                       commonFormat: .pcmFormatInt16, interleaved: true)
            defer { file.close() }
            let format = file.fileFormat.streamDescription.pointee
            let required = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            let forbidden = kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian |
                kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsAlignedHigh
            guard format.mFormatID == kAudioFormatLinearPCM, format.mSampleRate == 48_000,
                  format.mChannelsPerFrame == 1, format.mBitsPerChannel == 16,
                  format.mBytesPerFrame == 2, format.mBytesPerPacket == 2, format.mFramesPerPacket == 1,
                  format.mFormatFlags & required == required, format.mFormatFlags & forbidden == 0,
                  file.length > 0, file.length <= Self.maximumFrames, dataBytes == file.length * 2,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768) else {
                throw TelegramVoiceCaptureError.invalidRecording
            }
            var result: [Int16] = []
            result.reserveCapacity(Int(file.length))
            while result.count < file.length {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(32_768, file.length - Int64(result.count)))
                try file.read(into: buffer, frameCount: count)
                // AVAudioFile can return a shorter positive read before EOF (including raw PCM).
                // Continue until the independently checked CAF extent is exhausted; never trim it.
                guard buffer.frameLength > 0, buffer.frameLength <= count, let samples = buffer.int16ChannelData?[0] else {
                    throw TelegramVoiceCaptureError.invalidRecording
                }
                result.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
            }
            try Task.checkCancellation()
            guard file.framePosition == file.length else { throw TelegramVoiceCaptureError.invalidRecording }
            try validateSnapshot(original)
            return result
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            try validateSnapshot(original)
            if let error = error as? TelegramVoiceCaptureError { throw error }
            throw TelegramVoiceCaptureError.invalidRecording
        }
    }

    private func validateDirectory() throws {
        var held = stat(), path = stat()
        guard fstat(directoryFD, &held) == 0, lstat(directory.path, &path) == 0,
              path.st_mode & S_IFMT == S_IFDIR, held.st_uid == getuid(), held.st_mode & 0o777 == 0o700,
              held.st_dev == directoryIdentity.st_dev, held.st_ino == directoryIdentity.st_ino,
              path.st_dev == held.st_dev, path.st_ino == held.st_ino else {
            throw TelegramVoiceCaptureError.unavailable
        }
    }

    private func validateSnapshot(_ original: stat) throws {
        try validateDirectory()
        var held = stat(), path = stat()
        guard fstat(fileFD, &held) == 0, lstat(url.path, &path) == 0,
              path.st_mode & S_IFMT == S_IFREG, held.st_uid == getuid(), held.st_mode & 0o777 == 0o600,
              held.st_nlink == 1, path.st_dev == original.st_dev, path.st_ino == original.st_ino,
              held.st_dev == original.st_dev, held.st_ino == original.st_ino, held.st_size == original.st_size,
              held.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              held.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              held.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              held.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
            throw TelegramVoiceCaptureError.unavailable
        }
    }

    /// Check complete finite CAF chunk extents before native conversion can ignore an odd/trailing byte.
    /// These are our own closed recordings, so crash-era indefinite data chunks are not accepted.
    private func validateCAF(size: Int64) throws -> Int64 {
        guard try read(offset: 0, count: 8) == Data([0x63, 0x61, 0x66, 0x66, 0, 1, 0, 0]) else {
            throw TelegramVoiceCaptureError.invalidRecording
        }
        var offset: Int64 = 8, chunks = 0, description = false, dataBytes: Int64?
        while offset < size {
            try Task.checkCancellation()
            guard size - offset >= 12, chunks < 64 else { throw TelegramVoiceCaptureError.invalidRecording }
            let header = try read(offset: offset, count: 12)
            let length = header[4..<12].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard length <= UInt64(size - offset - 12) else { throw TelegramVoiceCaptureError.invalidRecording }
            let type = header.prefix(4)
            if type == Data("desc".utf8) {
                guard !description, offset == 8, length == 32 else { throw TelegramVoiceCaptureError.invalidRecording }
                description = true
            } else if type == Data("data".utf8) {
                // CAF's edit counter is bookkeeping; AVAudioFile increments it even for a new file.
                guard description, dataBytes == nil, length >= 4, (length - 4) % 2 == 0 else {
                    throw TelegramVoiceCaptureError.invalidRecording
                }
                dataBytes = Int64(length - 4)
            }
            offset += 12 + Int64(length); chunks += 1
        }
        guard let dataBytes, dataBytes > 0, dataBytes <= Self.maximumFrames * 2,
              size - dataBytes <= Self.maximumOverhead else { throw TelegramVoiceCaptureError.invalidRecording }
        return dataBytes
    }

    private func read(offset: Int64, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count), total = 0
        while total < count {
            try Task.checkCancellation()
            let amount = bytes.withUnsafeMutableBytes {
                pread(fileFD, $0.baseAddress!.advanced(by: total), count - total, off_t(offset + Int64(total)))
            }
            if amount < 0 && errno == EINTR { continue }
            guard amount > 0 else { throw TelegramVoiceCaptureError.invalidRecording }
            total += amount
        }
        return Data(bytes)
    }
}
