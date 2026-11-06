import Foundation

/// One file offered to a destination (Paperless now; chats, letters and AI
/// cards later). `produce` writes the bytes to a path inside a private
/// directory; the file must not exist yet.
public struct FileHandoff: Sendable {
    public let name: String
    public let byteCount: Int64?
    public let date: Date?
    public let produce: @Sendable (URL) async throws -> Void

    public init(name: String, byteCount: Int64? = nil, date: Date? = nil, produce: @escaping @Sendable (URL) async throws -> Void) {
        self.name = name
        self.byteCount = byteCount
        self.date = date
        self.produce = produce
    }

    /// A hand-off that copies an existing file (a staged copy, a lease).
    public init(copying source: URL, name: String, date: Date? = nil) {
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        self.init(name: name, byteCount: size, date: date) { url in try FileManager.default.copyItem(at: source, to: url) }
    }

    /// A safe on-disk basename: a generic stem plus a short ASCII extension.
    public var stagingBasename: String {
        let suffix = (name as NSString).pathExtension
        let valid =
            !suffix.isEmpty && suffix.utf8.count <= 16
            && suffix.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
        return valid ? "file." + suffix : "file"
    }
}
