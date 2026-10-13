import Foundation
import Combine
import MakoshCore

@MainActor public final class TelegramFileArchiveController: ObservableObject {
    public lazy var policy = TelegramConversationFilePolicyController { [weak self] in
        guard let self else { throw MessageArchiveError.invalid }
        return try self.open()
    }
    @Published public private(set) var status = "Сохранение файлов в S3 настраивается отдельно для каждого чата"
    @Published public private(set) var error: String?
    @Published public private(set) var isBusy = false
    @Published public private(set) var revision = 0
    private var repository: ArchiveFileRepository?
    private var configuration: (String,String,URL,URL)?
    private var active = Set<Lookup>()
    private struct Pending { let capture: ArchiveFileCapture; let identity: MessageArchiveIdentity; let attachment: MessageArchiveAttachment; let automatic: Bool }
    private var pending: [Lookup:Pending] = [:]
    private var automaticReservations: [UUID:Lookup] = [:]
    private var factory: (() throws -> ArchiveFileRepository)?
    private var resuming = false
    private struct Lookup: Hashable { let identity: MessageArchiveIdentity; let attachmentID: String }
    public init() {}
    init(factory: @escaping () throws -> ArchiveFileRepository) { self.factory = factory }
    func reserveAutomaticCapture(identity: MessageArchiveIdentity, attachment: MessageArchiveAttachment) -> (any TelegramMediaArchiveReservation)? {
        guard error == nil, !resuming,
              automaticReservations.count + pending.values.filter(\.automatic).count < 3 else { return nil }
        let id = UUID()
        automaticReservations[id] = .init(identity: identity, attachmentID: attachment.id)
        revision &+= 1
        return AutomaticReservation(owner: self, id: id, identity: identity, attachment: attachment)
    }
    private func cancelAutomaticReservation(_ id: UUID) {
        if automaticReservations.removeValue(forKey: id) != nil { revision &+= 1 }
    }
    private func consumeAutomaticReservation(_ id: UUID, file: URL, byteCount: Int64,
        identity: MessageArchiveIdentity, attachment: MessageArchiveAttachment) -> Bool {
        let lookup = Lookup(identity: identity, attachmentID: attachment.id)
        guard automaticReservations[id] == lookup else { return false }
        automaticReservations.removeValue(forKey: id)
        // Already granted capacity survives intervening archive errors and manual
        // pressure. No suspension separates reservation consumption and FD capture.
        let captured = acceptCapture(file: file, byteCount: byteCount, identity: identity, attachment: attachment, automatic: true)
        revision &+= 1; return captured
    }
    private final class AutomaticReservation: TelegramMediaArchiveReservation {
        private weak var owner: TelegramFileArchiveController?
        private let id: UUID, identity: MessageArchiveIdentity, attachment: MessageArchiveAttachment
        private var consumed = false
        init(owner: TelegramFileArchiveController, id: UUID, identity: MessageArchiveIdentity, attachment: MessageArchiveAttachment) {
            self.owner = owner; self.id = id; self.identity = identity; self.attachment = attachment
        }
        func capture(file: URL, byteCount: Int64) -> Bool {
            guard !consumed else { return false }; consumed = true
            return owner?.consumeAutomaticReservation(id, file: file, byteCount: byteCount, identity: identity, attachment: attachment) == true
        }
        func cancel() { guard !consumed else { return }; consumed = true; owner?.cancelAutomaticReservation(id) }
        isolated deinit { cancel() }
    }
    #if DEBUG
    func configureSynthetic(connectionString: String,schema: String,configurationFile: URL,spoolDirectory: URL) throws {
        guard (schema.hasPrefix("makosh_qa_") || schema.hasPrefix("qa_telegram_dossier_")), repository == nil else { throw MessageArchiveError.invalid }
        let configuration = try S3ConfigurationFile.read(configurationFile)
        guard configuration.endpoint == "http://127.0.0.1:55440" else { throw MessageArchiveError.invalid }
        repository = try ArchiveFileRepository(connectionString: connectionString,schema: schema,configuration: configuration,
            spoolDirectory: spoolDirectory,keyProvider: { _,_ in Data(repeating: 0x51,count: 32) })
    }
    #endif
    public func configure(connectionString: String,schema: String,configurationFile: URL,spoolDirectory: URL) {
        guard configuration == nil else { return }
        configuration = (connectionString,schema,configurationFile,spoolDirectory)
    }
    private func open() throws -> ArchiveFileRepository {
        if let repository { return repository }
        if let factory { let result = try factory(); repository = result; return result }
        guard let configuration else { throw S3ObjectStoreError.configuration }
        let result = try ArchiveFileRepository(connectionString: configuration.0,schema: configuration.1,
            configuration: S3ConfigurationFile.read(configuration.2),spoolDirectory: configuration.3)
        repository = result; return result
    }
    func pendingUploadFiles() throws -> TelegramPendingUploadFiles {
        TelegramPendingUploadFiles(repository: try open())
    }
    /// Called synchronously at complete-file delivery, before the first suspension.
    func accept(file: URL,byteCount: Int64,identity: MessageArchiveIdentity,attachment: MessageArchiveAttachment) {
        _ = acceptCapture(file: file, byteCount: byteCount, identity: identity, attachment: attachment, automatic: false)
    }
    private func acceptCapture(file: URL, byteCount: Int64, identity: MessageArchiveIdentity,
        attachment: MessageArchiveAttachment, automatic: Bool) -> Bool {
        let lookup = Lookup(identity: identity,attachmentID: attachment.id)
        guard pending[lookup] == nil, !active.contains(lookup) else { return true }
        do {
            // Preserve the existing eight-manual-capture budget. Automatic work
            // has three separately reserved slots, including outstanding fetches.
            guard automatic || pending.values.filter({ !$0.automatic }).count < 8 else { throw MessageArchiveError.invalid }
            let capture = try ArchiveFileCapture(file: file,byteCount: byteCount)
            pending[lookup] = Pending(capture: capture,identity: identity,attachment: attachment, automatic: automatic)
            start(lookup); return true
        } catch {
            self.error = "Не удалось захватить файл для S3. Повторите загрузку после восстановления хранилища."
            return false
        }
    }
    private func start(_ lookup: Lookup) {
        guard !active.contains(lookup), let pending = pending[lookup] else { return }
        do {
            let capture = try pending.capture.duplicate(), repository = try open()
            active.insert(lookup); isBusy = true; status = "Сохранение зашифрованной копии файла в S3…"
            Task { [weak self] in
                do {
                    let saved = try await repository.captureConversationFile(capture,identity: pending.identity,attachment: pending.attachment,
                        defaultEnabled: TelegramConversationFilePolicyController.defaultEnabled(identity: pending.identity))
                    guard let self else { return }
                    self.pending.removeValue(forKey: lookup)
                    self.status = saved == nil ? "Сохранение файлов для этого чата отключено" : "Файл сохранён в S3 отдельно от кеша Telegram"
                    if self.pending.isEmpty { self.error = nil }
                    self.finished(lookup)
                } catch {
                    guard let self else { return }
                    if (error as? ArchiveFileCaptureFailure)?.isQueued == true { self.pending.removeValue(forKey: lookup) }
                    self.error = "Копия файла ещё не подтверждена. Проверьте S3, PostgreSQL и Связку ключей, затем повторите запись. Подготовленные зашифрованные файлы остаются в очереди."
                    self.finished(lookup)
                }
            }
        } catch {
            self.error = "Не удалось подготовить копию файла для S3. Захват удерживается до повторной записи или закрытия приложения. Проверьте настройки хранилища."
        }
    }
    private func finished(_ lookup: Lookup) {
        active.remove(lookup); isBusy = !active.isEmpty || resuming; revision &+= 1
    }
    public func retry() {
        guard !resuming else { return }
        do {
            let repository = try open(); resuming = true; isBusy = true
            for lookup in pending.keys { start(lookup) }
            Task { [weak self] in
                do {
                    _ = try await repository.resume(legacyConversationDefault: TelegramConversationFilePolicyController.legacyDefault)
                    if let self, self.pending.isEmpty, self.active.isEmpty { self.error = nil; self.status = "Очередь сохранения файлов в S3 проверена" }
                } catch { self?.error = "Очередь файлов ещё не записана полностью. Проверьте хранилища и ключ архива; неподтверждённые копии сохранены." }
                guard let self else { return }
                self.resuming = false; self.isBusy = !self.active.isEmpty; self.revision &+= 1
            }
        } catch { self.error = "Хранилище файлов S3 не настроено или его конфигурация недоступна." }
    }
    public func file(identity: MessageArchiveIdentity,attachmentID: String) async throws -> ArchiveFileRecord? {
        try await open().files(identity: identity,attachmentID: attachmentID).first
    }
    /// Authenticated retained-S3 bytes; no MediaBox cache borrowing or fetch.
    public func preview(_ record: ArchiveFileRecord) async throws -> TelegramArchivedFilePreview {
        let repository = try open()
        return try await TelegramArchivedFilePreview.create(name: record.attachment.name) { destination in
            try await repository.export(record, to: destination)
        }
    }
    public func export(_ record: ArchiveFileRecord,to destination: URL) async throws {
        let repository = try open()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-archive-export-\(UUID().uuidString)",isDirectory: true)
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: false,attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("file")
        try await repository.export(record,to: local)
        try await TelegramDownloadedFileIO.copy(source: local,expectedSize: record.plaintextByteCount,destination: destination)
    }
}
