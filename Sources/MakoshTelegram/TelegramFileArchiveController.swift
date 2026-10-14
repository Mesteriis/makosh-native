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
    private var manualReservations: [UUID:Lookup] = [:]
    private struct WaitingManual {
        let capture: ArchiveFileCapture, identity: MessageArchiveIdentity, attachment: MessageArchiveAttachment
        let completion: (@MainActor (Bool) -> Void)?
        var checking = false, enabled = false
        var lookup: Lookup { .init(identity:identity,attachmentID:attachment.id) }
    }
    private var waitingManual: [UUID:WaitingManual] = [:]
    private struct DeferredManual {
        let file:URL, byteCount:Int64, identity:MessageArchiveIdentity, attachment:MessageArchiveAttachment
        let completion:@MainActor (Bool) -> Void
        var checking = false
    }
    // No FD or archive bytes: the media job still owns the native cache lease.
    // Only files admitted while OFF can enter here; a later ON waits for the
    // same eight-FD admission rather than silently discarding the new intent.
    private var deferredManual: [UUID:DeferredManual] = [:]
    func reserveManualDownload(identity:MessageArchiveIdentity,attachment:MessageArchiveAttachment) -> (any TelegramMediaArchiveReservation)? {
        guard !readOnly else { return nil }; return DownloadReservation(owner:self,identity:identity,attachment:attachment)
    }
    @MainActor private final class DownloadReservation: TelegramMediaArchiveReservation {
        private weak var owner:TelegramFileArchiveController?
        private let identity:MessageArchiveIdentity, attachment:MessageArchiveAttachment, id = UUID()
        private var inner:(any TelegramMediaArchiveReservation)?
        private var task:Task<Void,Never>?
        private var used = false
        init(owner:TelegramFileArchiveController,identity:MessageArchiveIdentity,attachment:MessageArchiveAttachment) {
            self.owner = owner; self.identity = identity; self.attachment = attachment
        }
        func prepare(completion:@escaping @MainActor (Bool) -> Void) {
            guard !used,task == nil,let owner else { completion(false); return }
            task = Task { [weak self] in
                guard let self else { return }
                do {
                    let repository = try owner.open()
                    let enabled = try await repository.conversationFileSavingEnabled(identity:self.identity,
                        defaultEnabled:TelegramConversationFilePolicyController.defaultEnabled(identity:self.identity))
                    guard !Task.isCancelled,!self.used else { return }; self.task = nil
                    if enabled {
                        self.inner = owner.reserveManualCapture(identity:self.identity,attachment:self.attachment)
                        completion(self.inner != nil)
                    } else { completion(true) }
                } catch {
                    guard !Task.isCancelled,!self.used else { return }; self.task = nil
                    let message = "Не удалось проверить правило S3 перед загрузкой. Повторите проверку хранилища."
                    if owner.error != message { owner.error = message }
                    completion(false)
                }
            }
        }
        func capture(file:URL,byteCount:Int64) -> Bool { false }
        func capture(file:URL,byteCount:Int64,completion:@escaping @MainActor (Bool) -> Void) {
            guard !used,let owner else { completion(false); return }; used = true
            if let inner { inner.capture(file:file,byteCount:byteCount,completion:completion) }
            else {
                guard owner.deferredManual.count < 1000 else { completion(false); return }
                owner.deferredManual[id] = .init(file:file,byteCount:byteCount,identity:identity,attachment:attachment,completion:completion)
                owner.armManualPolicyTimer(); owner.resolveDeferredManual(id)
            }
        }
        func cancel() {
            used = true; task?.cancel(); task = nil; inner?.cancel(); inner = nil
            if owner?.deferredManual.removeValue(forKey:id) != nil { owner?.updateBusy() }
        }
        isolated deinit { cancel() }
    }
    private func resolveDeferredManual(_ id:UUID) {
        guard var value = deferredManual[id],!value.checking else { return }
        value.checking = true; deferredManual[id] = value; updateBusy()
        Task { [weak self] in
            guard let self else { return }
            do {
                let repository = try self.open()
                let enabled = try await repository.conversationFileSavingEnabled(identity:value.identity,
                    defaultEnabled:TelegramConversationFilePolicyController.defaultEnabled(identity:value.identity))
                guard self.deferredManual[id] != nil else { return }
                self.deferredManual[id]?.checking = false
                if !enabled { self.deferredManual.removeValue(forKey:id); self.updateBusy(); value.completion(true) }
                else if let reservation = self.reserveManualCapture(identity:value.identity,attachment:value.attachment) {
                    self.deferredManual.removeValue(forKey:id)
                    reservation.capture(file:value.file,byteCount:value.byteCount,completion:value.completion)
                }
            } catch {
                guard self.deferredManual[id] != nil else { return }; self.deferredManual[id]?.checking = false
                self.error = "Не удалось проверить правило S3. Полученный файл удерживается в облачном кэше."
            }
            self.updateBusy()
        }
    }
    private var manualPolicyTimer: Task<Void,Never>?
    private var factory: (() throws -> ArchiveFileRepository)?
    private var resuming = false
    private var readOnly = false
    private struct Lookup: Hashable { let identity: MessageArchiveIdentity; let attachmentID: String }
    public init() {}
    init(factory: @escaping () throws -> ArchiveFileRepository) { self.factory = factory }
    isolated deinit { manualPolicyTimer?.cancel() }
    func reserveManualCapture(identity:MessageArchiveIdentity,attachment:MessageArchiveAttachment) -> (any TelegramMediaArchiveReservation)? {
        // Separate bounded FD admission lets an OFF chat finish even while
        // other uploads report an error or occupy all eight direct slots.
        guard !readOnly, manualReservations.count + waitingManual.count < 8 else { return nil }
        let id = UUID(); manualReservations[id] = .init(identity:identity,attachmentID:attachment.id)
        revision &+= 1
        return ManualReservation(owner:self,id:id,identity:identity,attachment:attachment)
    }
    private func cancelManualReservation(_ id:UUID) {
        if manualReservations.removeValue(forKey:id) != nil { revision &+= 1 }
    }
    private func consumeManualReservation(_ id:UUID,file:URL,byteCount:Int64,identity:MessageArchiveIdentity,
        attachment:MessageArchiveAttachment,completion:(@MainActor (Bool) -> Void)?) -> Bool {
        let lookup = Lookup(identity:identity,attachmentID:attachment.id)
        guard !readOnly, manualReservations[id] == lookup else { return false }
        manualReservations.removeValue(forKey:id)
        if pending[lookup] != nil || active.contains(lookup) { revision &+= 1; completion?(true); return true }
        do {
            // Freeze before any policy/queue suspension, including force unlink.
            let capture = try ArchiveFileCapture(file:file,byteCount:byteCount)
            waitingManual[id] = .init(capture:capture,identity:identity,attachment:attachment,completion:completion)
            status = "Проверка сохранения полученного файла…"; revision &+= 1
            armManualPolicyTimer(); resolveManualPolicy(id); return true
        } catch {
            self.error = "Не удалось захватить полученный файл для архива. Повторите загрузку."; revision &+= 1; return false
        }
    }
    private func resolveManualPolicy(_ id:UUID) {
        guard var value = waitingManual[id], !value.checking else { return }
        do {
            let repository = try open(); value.checking = true; waitingManual[id] = value; updateBusy()
            Task { [weak self] in
                do {
                    let enabled = try await repository.conversationFileSavingEnabled(identity:value.identity,
                        defaultEnabled:TelegramConversationFilePolicyController.defaultEnabled(identity:value.identity))
                    guard let self, self.waitingManual[id] != nil else { return }
                    self.waitingManual[id]?.checking = false
                    if enabled { self.waitingManual[id]?.enabled = true; self.drainManual() }
                    else {
                        let removed = self.waitingManual.removeValue(forKey:id)
                        self.status = "Сохранение файлов для этого чата отключено"; self.updateBusy(); self.revision &+= 1
                        removed?.completion?(true)
                    }
                } catch {
                    guard let self, self.waitingManual[id] != nil else { return }
                    self.waitingManual[id]?.checking = false
                    self.error = "Не удалось проверить правило S3. Полученный файл удерживается; повторите проверку хранилища."
                }
                self?.updateBusy()
            }
        } catch {
            self.error = "Хранилище файлов S3 недоступно. Полученные файлы удерживаются до повторной записи или закрытия приложения."
            updateBusy()
        }
    }
    private func drainManual() {
        while let id = waitingManual.first(where:{ $0.value.enabled && !$0.value.checking })?.key {
            guard let value = waitingManual[id] else { return }
            if pending[value.lookup] != nil || active.contains(value.lookup) {
                waitingManual.removeValue(forKey:id); revision &+= 1; value.completion?(true); continue
            }
            guard pending.values.filter({ !$0.automatic }).count < 8 else { break }
            waitingManual.removeValue(forKey:id)
            pending[value.lookup] = .init(capture:value.capture,identity:value.identity,attachment:value.attachment,automatic:false)
            start(value.lookup); revision &+= 1; value.completion?(true)
        }
        updateBusy()
    }
    private func refreshManualPolicies() {
        for id in Array(deferredManual.keys) where deferredManual[id]?.checking == false { resolveDeferredManual(id) }
        for id in Array(waitingManual.keys) where waitingManual[id]?.checking == false {
            waitingManual[id]?.enabled = false; resolveManualPolicy(id)
        }
    }
    private func armManualPolicyTimer() {
        guard manualPolicyTimer == nil else { return }
        manualPolicyTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(5)) } catch { return }
                guard self.map({ !$0.waitingManual.isEmpty || !$0.deferredManual.isEmpty }) == true else { return }; self?.refreshManualPolicies()
            }
        }
    }
    private func updateBusy() {
        isBusy = !active.isEmpty || resuming || waitingManual.values.contains(where:\.checking) || deferredManual.values.contains(where:\.checking)
        if waitingManual.isEmpty,deferredManual.isEmpty { manualPolicyTimer?.cancel(); manualPolicyTimer = nil }
    }
    private final class ManualReservation: TelegramMediaArchiveReservation {
        private weak var owner: TelegramFileArchiveController?
        private let id:UUID, identity:MessageArchiveIdentity, attachment:MessageArchiveAttachment
        private var used = false
        init(owner:TelegramFileArchiveController,id:UUID,identity:MessageArchiveIdentity,attachment:MessageArchiveAttachment) {
            self.owner = owner; self.id = id; self.identity = identity; self.attachment = attachment
        }
        func capture(file:URL,byteCount:Int64) -> Bool {
            guard !used else { return false }; used = true
            return owner?.consumeManualReservation(id,file:file,byteCount:byteCount,identity:identity,attachment:attachment,completion:nil) == true
        }
        func capture(file:URL,byteCount:Int64,completion:@escaping @MainActor (Bool) -> Void) {
            guard !used else { completion(false); return }; used = true
            if owner?.consumeManualReservation(id,file:file,byteCount:byteCount,identity:identity,attachment:attachment,completion:completion) != true { completion(false) }
        }
        func cancel() { guard !used else { return }; used = true; owner?.cancelManualReservation(id) }
        isolated deinit { cancel() }
    }
    func reserveAutomaticCapture(identity: MessageArchiveIdentity, attachment: MessageArchiveAttachment) -> (any TelegramMediaArchiveReservation)? {
        guard !readOnly, error == nil, !resuming,
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
    func configureReadOnly(connectionString: String, schema: String, keys: ArchiveBackupKeys, configurationFile: URL?, spoolDirectory: URL) {
        guard repository == nil, factory == nil, configuration == nil else { return }
        readOnly = true; status = "Файлы восстановленного архива · только просмотр"
        factory = {
            guard let configurationFile else { throw S3ObjectStoreError.configuration }
            return try ArchiveFileRepository(connectionString: connectionString, schema: schema,
                configuration: S3ConfigurationFile.read(configurationFile), spoolDirectory: spoolDirectory, readOnly: true,
                keyProvider: { id, creation in
                    guard !creation else { throw ArchiveBackupError.keyUnavailable }; return try keys.requireExisting(id)
                })
        }
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
        guard !readOnly else { return false }
        let lookup = Lookup(identity: identity,attachmentID: attachment.id)
        guard pending[lookup] == nil, !active.contains(lookup) else { return true }
        do {
            // Preserve the existing eight-manual-capture budget. Automatic work
            // has three separately reserved slots, including outstanding fetches.
            guard automatic || pending.values.filter({ !$0.automatic }).count + manualReservations.count + waitingManual.count < 8 else { throw MessageArchiveError.invalid }
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
                    if self.pending.isEmpty, self.waitingManual.isEmpty, self.deferredManual.isEmpty { self.error = nil }
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
        active.remove(lookup); drainManual(); updateBusy(); revision &+= 1
    }
    public func retry() {
        guard !readOnly, !resuming else { return }
        do {
            let repository = try open(); resuming = true; isBusy = true
            refreshManualPolicies(); drainManual()
            for lookup in pending.keys { start(lookup) }
            Task { [weak self] in
                do {
                    _ = try await repository.resume(legacyConversationDefault: TelegramConversationFilePolicyController.legacyDefault)
                    if let self, self.pending.isEmpty, self.active.isEmpty, self.waitingManual.isEmpty, self.deferredManual.isEmpty { self.error = nil; self.status = "Очередь сохранения файлов в S3 проверена" }
                } catch { self?.error = "Очередь файлов ещё не записана полностью. Проверьте хранилища и ключ архива; неподтверждённые копии сохранены." }
                guard let self else { return }
                self.resuming = false; self.updateBusy(); self.revision &+= 1
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
