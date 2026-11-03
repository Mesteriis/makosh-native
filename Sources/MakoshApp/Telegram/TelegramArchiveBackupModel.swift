import Foundation
import Combine
import MakoshCore

/// Immutable local configuration, never copied to the backup or the UI.
struct TelegramArchiveBackupContext: Sendable {
    let connectionString: String
    let schema: String
    let storageFile: URL?
    let keys: ArchiveBackupKeys
    let synthetic: Bool

    func storage() throws -> S3ObjectStoreConfiguration? {
        guard let storageFile, FileManager.default.fileExists(atPath: storageFile.path) else { return nil }
        let value = try S3ConfigurationFile.read(storageFile)
        if synthetic, value.endpoint != "http://127.0.0.1:55440" { throw ArchiveBackupError.invalid }
        return value
    }

    #if DEBUG
    /// Only the explicit QA entry calls this. No personal accounts or Keychain.
    func prepareSyntheticSource() async throws {
        guard synthetic, schema.hasPrefix("qa_telegram_dossier_") else { throw ArchiveBackupError.invalid }
        let key = Data(repeating: 0x51, count: 32)
        let store = try MessageArchiveStore(connectionString: connectionString, schema: schema) { _, _ in key }
        let identity = MessageArchiveIdentity(service: "telegram", accountID: "synthetic-backup", conversationID: "1", messageID: "0:14")
        let bytes = Data("Makosh block14 synthetic retained S3 file.\n".utf8)
        let attachment = MessageArchiveAttachment(id: "block14-file", kind: "file", name: "synthetic-retained.txt", size: Int64(bytes.count))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let ids = ["00000000-0000-4000-8000-000000000141", "00000000-0000-4000-8000-000000000142", "00000000-0000-4000-8000-000000000143"]
        let events: [MessageArchiveEvent] = [
            .message(.init(date: date, text: "Синтетический оригинал", author: "QA", isOutgoing: false, attachments: [attachment])),
            .message(.init(date: date, text: "Синтетическая правка", author: "QA", isOutgoing: false, attachments: [attachment])), .deleted
        ]
        _ = try store.append(zip(ids, events).map { id, event in
            .init(id: UUID(uuidString: id)!, identity: identity, observedAt: date, source: .synthetic, event: event)
        })
        if let configuration = try storage() {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-backup-qa-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let repository = try ArchiveFileRepository(connectionString: connectionString, schema: schema, configuration: configuration,
                spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _, _ in key })
            if try await repository.files(identity: identity, attachmentID: attachment.id).isEmpty {
                let file = root.appendingPathComponent("synthetic.txt"); try bytes.write(to: file, options: .withoutOverwriting)
                _ = try await repository.captureConversationFile(ArchiveFileCapture(file: file, byteCount: Int64(bytes.count)),
                    identity: identity, attachment: attachment, defaultEnabled: true)
            }
        }
    }
    #endif
}

@MainActor final class TelegramArchiveBackupModel: ObservableObject {
    @Published private(set) var package: URL?
    @Published private(set) var recoveryKey: URL?
    @Published private(set) var inspection: ArchiveBackupInspection?
    @Published private(set) var busy = false
    @Published private(set) var cancelling = false
    @Published private(set) var error: String?
    @Published private(set) var status = "Выберите копию и отдельный ключ для проверки."
    @Published private(set) var restoredSchema: String?
    @Published var targetSchema: String
    let context: TelegramArchiveBackupContext?
    private var worker: Task<Outcome, Never>?
    private enum Success: Sendable { case exported(ArchiveBackupSummary), inspected(ArchiveBackupInspection), restored(String, ArchiveBackupSummary) }
    private enum Outcome: Sendable { case success(Success), failure(String), cancelled }

    init(context: TelegramArchiveBackupContext?, restoreID: UUID = UUID()) {
        self.context = context
        targetSchema = (context?.synthetic == true ? "qa_telegram_dossier_r_" : "makosh_restored_") + restoreID.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
    }
    var canRestore: Bool {
        !busy && inspection != nil && context != nil && ArchiveBackup.isValidSchemaName(targetSchema)
            && (context?.synthetic != true || targetSchema.hasPrefix("qa_telegram_dossier_"))
            && targetSchema != context?.schema
    }
    func select(package: URL? = nil, key: URL? = nil) {
        guard !busy else { return }
        if let package { self.package = package }
        if let key { recoveryKey = key }
        inspection = nil; restoredSchema = nil; error = nil
        status = "Выбранные файлы ещё не проверены."
    }
    func export(to destination: URL, key: URL) {
        guard !busy, let context else { return }
        package = destination; recoveryKey = key; inspection = nil; restoredSchema = nil
        run(status: "Создание зашифрованной копии…") {
            #if DEBUG
            if context.synthetic { try await context.prepareSyntheticSource() }
            #endif
            return .exported(try await ArchiveBackup.export(connectionString: context.connectionString, schema: context.schema,
                configuration: context.storage(), to: destination, recoveryKey: key, keys: context.keys))
        }
    }
    func inspect() {
        guard !busy, let package, let recoveryKey else { return }
        inspection = nil
        run(status: "Проверка всех частей и файлов копии…") {
            .inspected(try ArchiveBackup.inspectReceipt(package: package, recoveryKey: recoveryKey))
        }
    }
    func restore(confirmed inspection: ArchiveBackupInspection, schema: String) {
        guard canRestore, self.inspection == inspection, targetSchema == schema,
              let package, let recoveryKey, let context else { return }
        restoredSchema = nil
        run(status: "Проверка назначения и восстановление…") {
            let reader = ArchiveBackupPolicyReader(connectionString: context.connectionString, schema: context.schema, keys: context.keys)
            let summary = try await ArchiveBackup.restore(package: package, recoveryKey: recoveryKey,
                connectionString: context.connectionString, schema: schema, configuration: context.storage(), keys: context.keys,
                currentPolicy: { try await reader.policy($0) }, currentOffPolicies: { try await reader.disabledPolicies() },
                expectedFingerprint: inspection.fingerprint)
            return .restored(schema, summary)
        }
    }
    func cancel() {
        guard busy else { return }; cancelling = true
        status = "Ожидание завершения текущей операции…"; worker?.cancel()
    }
    private func run(status: String, operation: @escaping @Sendable () async throws -> Success) {
        guard !busy else { return }
        busy = true; cancelling = false; error = nil; self.status = status
        let task = Task.detached(priority: .userInitiated) { () -> Outcome in
            do { try Task.checkCancellation(); return .success(try await operation()) }
            catch is CancellationError { return .cancelled }
            catch let error as ArchiveBackupError { return .failure(error.localizedDescription) }
            catch { return .failure("Операция не подтверждена. Проверьте PostgreSQL, S3, доступ к ключу и выбранным папкам. Перед повтором проверьте, появилось ли назначение.") }
        }
        worker = task
        Task { [weak self] in
            let result = await task.value
            guard let self else { return }
            self.busy = false; self.cancelling = false; self.worker = nil
            switch result {
            case let .success(.exported(summary)):
                self.status = "Копия создана: \(summary.messageVersions) снимков, \(summary.files) файлов. Храните ключ отдельно."
            case let .success(.inspected(value)):
                self.inspection = value; self.status = "Целостность всех частей и файлов подтверждена."
            case let .success(.restored(schema, summary)):
                self.restoredSchema = schema; self.status = "Восстановлено: \(summary.messageVersions) снимков, \(summary.files) файлов. Доступен просмотр."
            case let .failure(message): self.error = message; self.status = "Операция остановлена."
            case .cancelled: self.status = "Операция отменена. Существующие архивы не заменены."
            }
        }
    }
}
