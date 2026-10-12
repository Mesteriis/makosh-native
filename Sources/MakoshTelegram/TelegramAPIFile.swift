import Foundation
import Darwin

/// Reads only the explicitly selected credential file; never probes on initialization.
enum TelegramAPIFile {
    private struct Document: Decodable {
        let apiID: String
        let apiHash: String
    }
    private enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Не удалось загрузить настройки Telegram. Проверьте личный JSON-файл настроек и права доступа 0600."
        }
    }

    static func load(from url: URL) throws -> TelegramAPIConfiguration {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw Failure.unavailable }
        // Open first and inspect the same descriptor to avoid path-replacement races.
        // Nonblocking prevents an unexpected FIFO from blocking before fstat rejects it.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_mode & mode_t(0o077) == 0,
              metadata.st_size >= 0, metadata.st_size <= 8192 else { throw Failure.unavailable }
        // Bound the actual read as well: the file may grow after fstat.
        var bytes = [UInt8](repeating: 0, count: 8193)
        var count = 0
        while count < bytes.count {
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(descriptor, buffer.baseAddress!.advanced(by: count), buffer.count - count)
            }
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw Failure.unavailable
            }
            count += readCount
        }
        guard count <= 8192 else { throw Failure.unavailable }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(bytes.prefix(count)))
            return try TelegramAPIConfiguration(id: document.apiID, hash: document.apiHash)
        } catch {
            // Decoder and validation diagnostics must never expose credential content.
            throw Failure.unavailable
        }
    }
}
