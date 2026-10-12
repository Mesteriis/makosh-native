import Foundation
import Darwin

struct TelegramPlaybackFile: Sendable {
    let id: UUID
    let url: URL
    let directory: URL
}

enum TelegramPlaybackFileError: LocalizedError, Equatable {
    case unavailable, tooLarge, unsupported, preparationFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "Загруженный файл недоступен или изменён. Повторите загрузку."
        case .tooLarge: "Файл превышает ограничения воспроизведения."
        case .unsupported: "Этот файл не поддерживается для воспроизведения."
        case .preparationFailed: "Не удалось подготовить файл для воспроизведения."
        }
    }
}

enum TelegramPlaybackFileIO {
    static func prepare(source: URL, expectedSize: Int64) async throws -> TelegramPlaybackFile {
        try Task.checkCancellation()
        guard expectedSize > 0 else { throw TelegramPlaybackFileError.unavailable }
        guard expectedSize <= 4 * 1024 * 1024 * 1024 else { throw TelegramPlaybackFileError.tooLarge }
        guard source.isFileURL, !source.path.utf8.contains(0) else { throw TelegramPlaybackFileError.unavailable }
        let fd = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramPlaybackFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_size == expectedSize else { throw TelegramPlaybackFileError.unavailable }
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-playback-" + id.uuidString, isDirectory: true)
        // AVFoundation needs a container hint for some otherwise valid Ogg files.
        // Derive a fixed suffix from bytes, never from a message name/MIME label.
        var header = [UInt8](repeating: 0, count: 12)
        let read = pread(fd, &header, header.count, 0)
        let suffix: String
        if read >= 4, Array(header.prefix(4)) == Array("OggS".utf8) { suffix = ".ogg" }
        else if read >= 12, Array(header.prefix(4)) == Array("RIFF".utf8), Array(header.suffix(4)) == Array("WAVE".utf8) { suffix = ".wav" }
        else if read >= 8, Array(header[4..<8]) == Array("ftyp".utf8) { suffix = ".mp4" }
        else { suffix = "" }
        let url = directory.appendingPathComponent("payload-" + id.uuidString + suffix)
        guard mkdir(directory.path, 0o700) == 0 else { throw TelegramPlaybackFileError.preparationFailed }
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        guard chmod(directory.path, 0o700) == 0 else { throw TelegramPlaybackFileError.preparationFailed }
        do {
            try await TelegramDownloadedFileIO.copy(source: source, expectedSize: expectedSize, destination: url)
        } catch is CancellationError { throw CancellationError() }
        catch TelegramFileError.unavailable { throw TelegramPlaybackFileError.unavailable }
        catch { throw TelegramPlaybackFileError.preparationFailed }
        try Task.checkCancellation()
        var final = stat(), current = stat()
        guard fstat(fd, &final) == 0, lstat(source.path, &current) == 0,
              current.st_dev == original.st_dev, current.st_ino == original.st_ino,
              final.st_size == original.st_size,
              final.st_mtimespec.tv_sec == original.st_mtimespec.tv_sec,
              final.st_mtimespec.tv_nsec == original.st_mtimespec.tv_nsec,
              final.st_ctimespec.tv_sec == original.st_ctimespec.tv_sec,
              final.st_ctimespec.tv_nsec == original.st_ctimespec.tv_nsec else {
            throw TelegramPlaybackFileError.unavailable
        }
        complete = true
        return TelegramPlaybackFile(id: id, url: url, directory: directory)
    }

    static func discard(_ file: TelegramPlaybackFile) throws {
        let expected = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-playback-" + file.id.uuidString, isDirectory: true)
        let names = ["", ".ogg", ".wav", ".mp4"].map { "payload-" + file.id.uuidString + $0 }
        guard file.directory.standardizedFileURL == expected.standardizedFileURL,
              names.contains(where: { file.url.standardizedFileURL == expected.appendingPathComponent($0).standardizedFileURL }) else {
            throw TelegramPlaybackFileError.preparationFailed
        }
        var info = stat()
        if lstat(file.directory.path, &info) != 0 {
            if errno == ENOENT { return }
            throw TelegramPlaybackFileError.preparationFailed
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw TelegramPlaybackFileError.preparationFailed
        }
        do { try FileManager.default.removeItem(at: file.directory) }
        catch { throw TelegramPlaybackFileError.preparationFailed }
    }
}
