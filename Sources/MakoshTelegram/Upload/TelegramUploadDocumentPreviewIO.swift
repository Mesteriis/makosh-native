import Foundation
import Darwin
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

public struct TelegramUploadDocumentPreviewSnapshot: Sendable {
    public enum Kind: Equatable, Sendable { case file, graphic, music, sticker }
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public let image: TelegramImagePreview?
}

public enum TelegramUploadDocumentPreviewIO {
    /// Only an owned preparation is decoded. Image/PDF input is limited to 20MiB,
    /// 256 frames/pages, 8192 per axis, 40Mpixels and a 320px output thumbnail.
    /// PDF bounds describe input/page/output geometry, not parser peak memory or CPU.
    public static func preview(_ file: TelegramUploadFile) async throws -> TelegramUploadDocumentPreviewSnapshot {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) { try await previewOwned(file) }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }

    private static func previewOwned(_ file: TelegramUploadFile) async throws -> TelegramUploadDocumentPreviewSnapshot {
        try Task.checkCancellation()
        guard file.mode == .file else { throw TelegramUploadFileError.unavailable }
        try TelegramUploadFileIO.validateOwnedStage(file)
        let fd = Darwin.open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TelegramUploadFileError.unavailable }
        defer { Darwin.close(fd) }
        var original = stat()
        guard fstat(fd, &original) == 0, original.st_mode & S_IFMT == S_IFREG,
              original.st_uid == getuid(), original.st_mode & 0o777 == 0o600,
              original.st_size == file.size else { throw TelegramUploadFileError.unavailable }
        try await TelegramUploadFileIO.verifyMetadata(file)
        let result: TelegramUploadDocumentPreviewSnapshot
        if case let .audio(audio)? = file.metadata {
            let title = audio.title.isEmpty && audio.performer.isEmpty ? file.name : audio.title + " - " + audio.performer
            let seconds = Int(audio.duration), hours = seconds / 3600
            let duration = hours > 0 ? String(format: "%d:%02d:%02d", hours, (seconds / 60) % 60, seconds % 60)
                : String(format: "%d:%02d", seconds / 60, seconds % 60)
            result = .init(kind: .music, title: title, subtitle: duration, image: nil)
        } else {
            let mime = TelegramUploadSourceFactsIO.selectionMIME(for: file.name)
            let typedWebP: Bool
            if case .webP? = file.metadata { typedWebP = true } else { typedWebP = false }
            if (mime.hasPrefix("image") || mime.hasSuffix("pdf") || typedWebP), file.size > 0,
               file.size <= 20 * 1024 * 1024 {
                result = try decode(read(fd: fd, size: Int(file.size)), file: file,
                    stickerEligible: typedWebP || mime == "image/webp")
            } else { result = generic(file) }
        }
        try Task.checkCancellation()
        try TelegramUploadVideoIO.validateSnapshot(file, fd: fd, original: original)
        return result
    }

    private static func generic(_ file: TelegramUploadFile) -> TelegramUploadDocumentPreviewSnapshot {
        .init(kind: .file, title: file.name,
            subtitle: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file), image: nil)
    }

    private static func read(fd: Int32, size: Int) throws -> Data {
        var bytes = Data(count: size)
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < size {
                try Task.checkCancellation()
                let actual = pread(fd, buffer.baseAddress!.advanced(by: offset), min(size - offset, 1_048_576), Int64(offset))
                if actual < 0 && errno == EINTR { continue }
                guard actual > 0 else { throw TelegramUploadFileError.unavailable }
                offset += actual
            }
        }
        return bytes
    }

    private static func decode(_ bytes: Data, file: TelegramUploadFile,
                               stickerEligible: Bool) throws -> TelegramUploadDocumentPreviewSnapshot {
        try autoreleasepool {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let identifier = CGImageSourceGetType(source), CGImageSourceGetStatus(source) == .statusComplete,
                  (1...256).contains(CGImageSourceGetCount(source)),
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return generic(file) }
            let type = identifier as String, count = CGImageSourceGetCount(source)
            if type == "com.adobe.pdf" {
                guard let provider = CGDataProvider(data: bytes as CFData), let document = CGPDFDocument(provider),
                      !document.isEncrypted, (1...256).contains(document.numberOfPages),
                      let page = document.page(at: 1), safe(page.getBoxRect(.mediaBox)), safe(page.getBoxRect(.cropBox)) else {
                    return generic(file)
                }
            } else {
                guard UTType(type)?.conforms(to: .image) == true,
                      let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return generic(file) }
                let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
                guard let dimensions = dimensions(global ?? first) ?? dimensions(first), safe(dimensions),
                      dimensions.width * dimensions.height * Double(count) <= 256_000_000 else { return generic(file) }
            }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 320,
                kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  image.width > 0, image.height > 0, image.width <= 320, image.height <= 320 else { return generic(file) }
            try Task.checkCancellation()
            let preview = TelegramImagePreview(image: image, originalExtension: UTType(type)?.preferredFilenameExtension,
                originalSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            return .init(kind: stickerEligible && type == "org.webmproject.webp" && count == 1 ? .sticker : .graphic,
                title: file.name, subtitle: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file), image: preview)
        }
    }

    private static func dimensions(_ properties: [CFString: Any]) -> CGRect? {
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private static func safe(_ rectangle: CGRect) -> Bool {
        rectangle.origin.x.isFinite && rectangle.origin.y.isFinite && rectangle.width.isFinite && rectangle.height.isFinite &&
            rectangle.width > 0 && rectangle.height > 0 && rectangle.width <= 8192 && rectangle.height <= 8192 &&
            rectangle.width * rectangle.height <= 40_000_000
    }
}
