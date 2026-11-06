import Foundation

/// A private copy handed to a composer or an AI card.
public struct StagedFile: Sendable, Equatable {
    public let id: UUID
    public let url: URL
    public let name: String
}

/// Private copies under one 0700 root: a directory per copy, the file 0600,
/// a generic basename. Nothing survives a restart; `clearAll` runs at launch.
public actor FileHandoffStage {
    private let root: URL
    private var files: [UUID: StagedFile] = [:]

    public init(root: URL) { self.root = root }

    public func stage(_ handoff: FileHandoff) async throws -> StagedFile {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(handoff.stagingBasename, isDirectory: false)
        do {
            try await handoff.produce(url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        let staged = StagedFile(id: id, url: url, name: handoff.name)
        files[id] = staged
        return staged
    }

    /// Nil once released, or for a copy from an earlier run.
    public func url(id: UUID) -> URL? { files[id]?.url }

    public func release(id: UUID) {
        guard let staged = files.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: staged.url.deletingLastPathComponent())
    }

    public func clearAll() {
        files = [:]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for entry in entries { try? FileManager.default.removeItem(at: entry) }
    }
}
