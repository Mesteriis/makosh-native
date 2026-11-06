import Foundation

/// A private plaintext copy for Quick Look: its own 0700 directory, a 0600
/// file with a generic name, removed when the lease is released.
public final class FilePreviewLease: Sendable, Identifiable {
    public let id: UUID
    public let file: URL
    public let name: String
    private let directory: URL

    private init(id: UUID, file: URL, name: String, directory: URL) {
        self.id = id
        self.file = file
        self.name = name
        self.directory = directory
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    public static func create(name: String, export: @Sendable (URL) async throws -> Void) async throws -> FilePreviewLease {
        try Task.checkCancellation()
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "makosh-file-preview-\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var transferred = false
        defer { if !transferred { try? FileManager.default.removeItem(at: directory) } }
        let file = directory.appendingPathComponent(FileHandoff(name: name) { _ in }.stagingBasename, isDirectory: false)
        try await export(file)
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let lease = FilePreviewLease(id: id, file: file, name: name, directory: directory)
        transferred = true
        return lease
    }
}
