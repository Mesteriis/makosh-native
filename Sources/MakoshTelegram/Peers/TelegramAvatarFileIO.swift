import Foundation

enum TelegramAvatarFileIO {
    static func image(source: URL, expectedSize: Int64, size: TelegramAvatarSize) async throws -> TelegramImagePreview {
        try await TelegramDownloadedFileIO.image(source: source, expectedSize: expectedSize,
            maximumBytes: 2 * 1_024 * 1_024, maximumDimension: 4_096,
            maximumPixels: 16_000_000, thumbnailPixelSize: size == .small ? 128 : 512)
    }
}
