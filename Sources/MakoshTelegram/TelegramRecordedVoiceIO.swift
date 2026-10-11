import Foundation
import Darwin
import CryptoKit

public enum TelegramRecordedVoiceIO {
    public static func prepare(samples: [Int16]) async throws -> TelegramUploadFile {
        let bytes = try await TelegramRecordedVoiceCodec.encode(samples: samples)
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try stage(bytes, sampleCount: Int32(samples.count)) }
        let file = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        do { try Task.checkCancellation(); return file }
        catch { try? TelegramUploadFileIO.discard(file); throw error }
    }

    private static func stage(_ bytes: Data, sampleCount: Int32) throws -> TelegramUploadFile {
        try Task.checkCancellation()
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-upload-" + id.uuidString, isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw TelegramUploadFileError.stagingFailed }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        let url = directory.appendingPathComponent("payload-" + id.uuidString)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TelegramUploadFileError.stagingFailed }
        defer { Darwin.close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw TelegramUploadFileError.stagingFailed }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), min(65_536, buffer.count - offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TelegramUploadFileError.stagingFailed }
                offset += count
            }
        }
        try Task.checkCancellation()
        let metadata = TelegramUploadVoiceMetadata(sampleCount: sampleCount, plaintextSHA256: digest(bytes))
        let file = TelegramUploadFile(id: id, name: "Voice.ogg", size: Int64(bytes.count), mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: url, directory: directory, metadata: .voice(metadata))
        try TelegramUploadFileIO.validateOwnedStage(file)
        success = true
        return file
    }

    struct Facts: Equatable, Sendable {
        let sampleCount: Int32
        let plaintextSHA256: String
    }

    /// Decode actual owned bytes; never trust the persisted sample count as an input.
    static func inspect(_ file: TelegramUploadFile) async throws -> Facts {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try await inspectOwned(file) }
        let facts = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return facts
    }

    private static func inspectOwned(_ file: TelegramUploadFile) async throws -> Facts {
        try Task.checkCancellation()
        try TelegramUploadFileIO.validateOwnedStage(file)
        guard file.mode == .file, file.size > 0, file.size <= TelegramRecordedVoiceCodec.maximumBytes else {
            throw TelegramUploadFileError.invalidVoice
        }
        let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG, original.st_uid == getuid(),
              original.st_mode & 0o777 == 0o600, original.st_size == file.size else { throw TelegramUploadFileError.unavailable }
        do {
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
            bytes.reserveCapacity(Int(file.size))
            while bytes.count < file.size {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes {
                    pread(fd, $0.baseAddress!, min($0.count, Int(file.size) - bytes.count), off_t(bytes.count))
                }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TelegramUploadFileError.unavailable }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            let pcm = try await TelegramRecordedVoiceCodec.decodeRecording(bytes)
            try Task.checkCancellation()
            try TelegramUploadVideoIO.validateSnapshot(file, fd: fd, original: original)
            return Facts(sampleCount: Int32(pcm.count), plaintextSHA256: digest(bytes))
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            try TelegramUploadVideoIO.validateSnapshot(file, fd: fd, original: original)
            if let error = error as? TelegramUploadFileError { throw error }
            throw TelegramUploadFileError.invalidVoice
        }
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
