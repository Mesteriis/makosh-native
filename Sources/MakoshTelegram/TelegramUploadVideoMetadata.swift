import Foundation
import UniformTypeIdentifiers

/// Frozen video preparation, distinct from final message grouping. In particular,
/// the reference prepares an ordinary singleton with inCollage=true.
public struct TelegramUploadVideoMetadata: Codable, Equatable, Sendable {
    public let width: Int32
    public let height: Int32
    public let duration: Double
    public let hasAudio: Bool
    public let inCollage: Bool

    func isValid(name: String, size: Int64) -> Bool {
        width > 0 && height > 0 && width <= 8192 && height <= 8192 &&
        Int64(width) * Int64(height) <= 40_000_000 &&
        duration.isFinite && duration > 0 && duration <= 7 * 24 * 60 * 60 &&
        duration == Double(Float32(duration)) &&
        size > 0 && size <= 4 * 1024 * 1024 * 1024 &&
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType?.hasPrefix("video/") == true
    }
}
