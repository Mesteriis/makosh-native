import Foundation

/// Owns one authenticated plaintext preview. Retain this lease for the complete
/// native preview lifetime; cleanup happens only when the last owner releases it.
public final class TelegramArchivedFilePreview: Sendable, Identifiable {
    public let id: UUID
    public let file: URL
    public let name: String
    private let directory: URL

    private init(id: UUID, file: URL, name: String, directory: URL) {
        self.id = id; self.file = file; self.name = name; self.directory = directory
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @MainActor static func create(name: String,
        export: @MainActor (URL) async throws -> Void) async throws -> TelegramArchivedFilePreview {
        try Task.checkCancellation()
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-archive-preview-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        var transferred = false
        defer { if !transferred { try? FileManager.default.removeItem(at: directory) } }
        let suffix = (name as NSString).pathExtension
        let validExtension = !suffix.isEmpty && suffix.utf8.count <= 16 && suffix.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
        let basename = validExtension ? "file." + suffix : "file"
        let file = directory.appendingPathComponent(basename, isDirectory: false)
        try Task.checkCancellation()
        try await export(file)
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let lease = TelegramArchivedFilePreview(id: id, file: file, name: telegramAttachmentName(name), directory: directory)
        transferred = true
        return lease
    }
}
