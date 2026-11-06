import Foundation

/// What the sender and the section need from a Paperless server; the real
/// client conforms, tests script it.
public protocol PaperlessServing: Sendable {
    func status() async throws -> PaperlessStatus
    func tags() async throws -> [PaperlessNamed]
    func documentTypes() async throws -> [PaperlessNamed]
    func documents(query: String, page: Int) async throws -> PaperlessPage<PaperlessDocument>
    func download(id: Int, original: Bool, to destination: URL) async throws
    func upload(file: URL, name: String, options: PaperlessUpload) async throws -> String
    func task(id: String) async throws -> PaperlessTaskState
    func documentURL(id: Int) -> URL
}

extension PaperlessClient: PaperlessServing {}

public struct PaperlessSubmission: Codable, Equatable, Identifiable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        case uploading, processing
        case accepted(documentID: Int?)
        case duplicate(existingID: Int?)
        case failed(reason: String)
        /// The upload left without an answer: Paperless may or may not have it.
        case unknown
    }
    public let id: UUID
    public let connectionID: UUID
    public let fileName: String
    public let title: String
    public var taskID: String?
    public var state: State
    public let startedAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), connectionID: UUID, fileName: String, title: String, taskID: String? = nil, state: State, startedAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.connectionID = connectionID
        self.fileName = fileName
        self.title = title
        self.taskID = taskID
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }
    public var isSettled: Bool {
        state.isSettled
    }
}

extension PaperlessSubmission.State {
    public var isSettled: Bool {
        switch self {
        case .accepted, .duplicate, .failed: true
        case .uploading, .processing, .unknown: false
        }
    }
    /// What the person reads on the send sheet and in the catalogue.
    public var title: String {
        switch self {
        case .uploading: "Загружается…"
        case .processing: "Обрабатывается…"
        case .accepted(let id): id.map { "Документ принят · #\($0)" } ?? "Документ принят"
        case .duplicate(let id): FilesFailure.duplicate(existingID: id).errorDescription ?? ""
        case .failed(let reason): "Не отправлено: \(reason)"
        case .unknown: "Результат неизвестен — проверьте в Paperless"
        }
    }
}

/// Sends files to Paperless and keeps every attempt in a private journal, so
/// "processing" and "unknown" survive a restart. Nothing is ever resent by itself.
public actor PaperlessSender {
    public static let pollInterval: Duration = .seconds(2)
    public static let pollLimit: Duration = .seconds(180)
    private static let journalLimit = 500
    public typealias ClientFactory = @Sendable (PaperlessConnection, String) -> any PaperlessServing
    private let registry: FileStorageRegistry
    private let vault: FileStorageTokenVault
    private let journal: URL
    private let clientFactory: ClientFactory
    private let sleep: @Sendable (Duration) async throws -> Void
    private var loaded = false
    private var records: [PaperlessSubmission] = []
    public private(set) var lastJournalFailure: String?

    public init(
        registry: FileStorageRegistry, vault: FileStorageTokenVault, journal: URL,
        clientFactory: @escaping ClientFactory = { PaperlessClient(connection: $0, token: $1) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.registry = registry
        self.vault = vault
        self.journal = journal
        self.clientFactory = clientFactory
        self.sleep = sleep
    }

    public func submissions() -> [PaperlessSubmission] {
        load()
        return records
    }

    /// Exports, uploads and polls; every state change reaches the journal before `progress`.
    public func send(
        _ handoff: FileHandoff, to connectionID: UUID, options: PaperlessUpload, progress: @Sendable (PaperlessSubmission) -> Void
    ) async -> PaperlessSubmission {
        load()
        var submission = PaperlessSubmission(
            connectionID: connectionID, fileName: handoff.name, title: options.title, state: .uploading, startedAt: Date(),
            updatedAt: Date())
        guard let client = await client(connectionID) else {
            return update(submission, .failed(reason: describe(FilesFailure.storageMissing)), progress)
        }
        let server: any PaperlessServing
        switch client {
        case .success(let value): server = value
        case .failure(let failure): return update(submission, .failed(reason: describe(failure)), progress)
        }
        submission = update(submission, .uploading, progress)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "makosh-handoff-\(submission.id.uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(handoff.stagingBasename, isDirectory: false)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try await handoff.produce(file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            return update(submission, .failed(reason: describe(error)), progress)
        }
        do {
            submission.taskID = try await server.upload(file: file, name: handoff.name, options: options)
        } catch let failure as FilesFailure {
            if case .unreachable = failure { return update(submission, .unknown, progress) }
            return update(submission, .failed(reason: describe(failure)), progress)
        } catch {
            return update(submission, .failed(reason: describe(error)), progress)
        }
        submission = update(submission, .processing, progress)
        return await poll(submission, server: server, progress: progress)
    }

    /// Asks Paperless about one processing/unknown submission; nothing is uploaded.
    @discardableResult public func check(_ id: UUID) async -> PaperlessSubmission? {
        load()
        guard let submission = records.first(where: { $0.id == id }) else { return nil }
        guard !submission.isSettled, let taskID = submission.taskID else { return submission }
        guard case .success(let server)? = await client(submission.connectionID) else { return submission }
        do {
            let state = try await server.task(id: taskID)
            if let settled = Self.settle(state) { return update(submission, settled, { _ in }) }
            return submission
        } catch { return submission }
    }

    /// Re-queries every unsettled submission with a task ID, once.
    public func resume() async {
        load()
        for submission in records where !submission.isSettled && submission.taskID != nil {
            await check(submission.id)
        }
    }

    // MARK: - Steps

    private func poll(
        _ start: PaperlessSubmission, server: any PaperlessServing, progress: @Sendable (PaperlessSubmission) -> Void
    ) async -> PaperlessSubmission {
        let submission = start
        guard let taskID = submission.taskID else { return submission }
        var elapsed: Duration = .zero
        while true {
            do {
                let state = try await server.task(id: taskID)
                if let settled = Self.settle(state) { return update(submission, settled, progress) }
            } catch {
                // The server went quiet mid-processing: the task ID stays for a later check.
                return submission
            }
            guard elapsed < Self.pollLimit else { return submission }
            do { try await sleep(Self.pollInterval) } catch { return submission }
            elapsed += Self.pollInterval
        }
    }

    static func settle(_ state: PaperlessTaskState) -> PaperlessSubmission.State? {
        switch state {
        case .pending, .started: return nil
        case .success(let id): return .accepted(documentID: id)
        case .failure(let message):
            guard message.range(of: "duplicate", options: .caseInsensitive) != nil else { return .failed(reason: message) }
            let existing = message.range(of: #"\(#\d+\)"#, options: .regularExpression).map { message[$0].dropFirst(2).dropLast() }.flatMap
            { Int($0) }
            return .duplicate(existingID: existing)
        }
    }

    private func client(_ connectionID: UUID) async -> Result<any PaperlessServing, FilesFailure>? {
        guard case .paperless(let connection)? = registry.connections().first(where: { $0.id == connectionID }) else { return nil }
        do {
            guard let token = try await vault.load(connectionID: connection.id) else { return .failure(.unauthorized) }
            return .success(clientFactory(connection, token))
        } catch let failure as FilesFailure { return .failure(failure) } catch { return .failure(.keyUnavailable) }
    }

    private func describe(_ error: Error) -> String {
        (error as? FilesFailure)?.errorDescription ?? (error as? LocalizedError)?.errorDescription ?? String(describing: type(of: error))
    }

    @discardableResult private func update(
        _ submission: PaperlessSubmission, _ state: PaperlessSubmission.State, _ progress: @Sendable (PaperlessSubmission) -> Void
    ) -> PaperlessSubmission {
        var value = submission
        value.state = state
        value.updatedAt = Date()
        if let index = records.firstIndex(where: { $0.id == value.id }) { records[index] = value } else { records.append(value) }
        if records.count > Self.journalLimit { records.removeFirst(records.count - Self.journalLimit) }
        save()
        progress(value)
        return value
    }

    // MARK: - Journal

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        do {
            records = try JSONDecoder().decode([PaperlessSubmission].self, from: Data(contentsOf: journal))
        } catch {
            records = []
            lastJournalFailure = "Журнал отправок повреждён и начат заново."
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            let directory = journal.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let temporary = directory.appendingPathComponent(".\(journal.lastPathComponent).\(UUID().uuidString)")
            try data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(journal, withItemAt: temporary)
            lastJournalFailure = nil
        } catch {
            lastJournalFailure = "Не удалось записать журнал отправок."
        }
    }
}
