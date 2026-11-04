import SwiftUI
import AppKit
import MakoshCore
import MakoshTelegram
import MakoshMail
import MakoshWhatsApp
import MakoshTeams
import MakoshTelemost
import UniformTypeIdentifiers

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var contacts: [Contact] = []
    @Published var duplicates: [DuplicateCandidate] = []
    @Published var merges: [MergeRecord] = []
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { selectionRevision &+= 1 } }
    }
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var writesBlocked = false
    private var selectionRevision: UInt64 = 0
    private let worker: ContactWorkspaceWorker
    private var archiveConfiguration: ContactWorkspaceConfiguration?
    @Published private(set) var archiveBackupContext: TelegramArchiveBackupContext?
    #if DEBUG
    private var pendingUploadQAConfigured = false
    #endif
    init(requireExplicitDatabaseConfiguration: Bool = false, syntheticSchemaPrefix: String = "qa_telegram_dossier_") {
        worker = ContactWorkspaceWorker(
            requireExplicitDatabaseConfiguration: requireExplicitDatabaseConfiguration, syntheticSchemaPrefix: syntheticSchemaPrefix)
    }
    init(worker: ContactWorkspaceWorker) { self.worker = worker }

    /// The view owns startup lifetime; constructing the conductor performs no IO.
    func load() async {
        guard !ready, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let opened = try await worker.open()
            archiveConfiguration = opened.configuration
            publish(opened.snapshot)
            ready = true
        } catch { self.error = error.localizedDescription }
    }
    var dossierWorker: ContactWorkspaceWorker { worker }
    var mailConfiguration: ContactWorkspaceConfiguration? { archiveConfiguration }
    var selected: Contact? { contacts.first { $0.id == selectedID } }
    var canWrite: Bool { ready && !busy && !writesBlocked }
    func configureArchive(_ archive: TelegramArchiveController, synthetic: Bool = false) {
        guard let configuration = archiveConfiguration else { return }
        let schema = configuration.archiveSchema ?? configuration.schema
        if !synthetic { archive.configure(connectionString: configuration.connectionString, schema: schema) }
        let args = CommandLine.arguments
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "Makosh", isDirectory: true)
        let storage: URL
        if let index = args.firstIndex(of: "--storage-config"), args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") {
            storage = URL(fileURLWithPath: args[index + 1])
        } else {
            storage = support.appendingPathComponent("s3.json")
        }
        if !synthetic {
            archive.files.configure(
                connectionString: configuration.connectionString, schema: schema,
                configurationFile: storage, spoolDirectory: support.appendingPathComponent("FileArchiveQueue", isDirectory: true))
        }
        if archiveBackupContext == nil {
            let keys: ArchiveBackupKeys
            #if DEBUG
            if synthetic {
                guard schema.hasPrefix("qa_telegram_dossier_") else { return }
                keys = .init(
                    lookup: { _ in Data(repeating: 0x51, count: 32) },
                    install: { _, key in
                        guard key == Data(repeating: 0x51, count: 32) else { throw ArchiveBackupError.conflict }
                    })
            } else {
                keys = .keychain
            }
            #else
            keys = .keychain
            #endif
            archiveBackupContext = .init(
                connectionString: configuration.connectionString, schema: schema,
                storageFile: storage, keys: keys, synthetic: synthetic)
        }
    }
    #if DEBUG
    func configurePendingUploadRecoveryQAIfRequested(_ telegram: TelegramModel) {
        let args = CommandLine.arguments
        guard args.contains("--telegram-pending-upload-qa"), !pendingUploadQAConfigured else { return }
        guard telegram.isSyntheticPreview, let configuration = archiveConfiguration,
            configuration.schema.hasPrefix("qa_telegram_dossier_"),
            let storageIndex = args.firstIndex(of: "--storage-config"), args.indices.contains(storageIndex + 1),
            !args[storageIndex + 1].hasPrefix("--"),
            let draftsIndex = args.firstIndex(of: "--telegram-drafts-synthetic-preview"), args.indices.contains(draftsIndex + 1),
            !args[draftsIndex + 1].hasPrefix("--")
        else {
            error =
                "Восстановление вложений в синтетической проверке требует явных конфигураций S3, отдельной схемы PostgreSQL и тестового Postbox."
            return
        }
        do {
            let directory = URL(fileURLWithPath: args[draftsIndex + 1], isDirectory: true)
            try telegram.configurePendingUploadRecoveryQA(
                connectionString: configuration.connectionString,
                schema: configuration.schema, configurationFile: URL(fileURLWithPath: args[storageIndex + 1]),
                spoolDirectory: directory.appendingPathComponent("PendingUploadArchiveQueue", isDirectory: true),
                albums: args.contains("--telegram-albums-qa"))
            pendingUploadQAConfigured = true
        } catch { self.error = "Не удалось подготовить отдельное хранилище восстановления синтетических вложений." }
    }
    #endif
    @discardableResult func reload() async -> Bool {
        guard ready, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            publish(try await worker.snapshot())
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    func save(_ draft: ContactDraft, id: UUID?) async -> Bool {
        await perform(.save(draft: draft, id: id), selectResult: true) != nil
    }
    func linkTelegramProfile(
        _ profile: TelegramContactProfile, telegram: TelegramModel,
        contextID: UUID, contactID: UUID?
    ) async -> UUID? {
        guard telegram.isCurrentContactProfile(profile, contextID: contextID), profile.isPerson else {
            error = "Карточка собеседника изменилась. Откройте её заново."
            return nil
        }
        let result = await perform(
            .link(
                profile.dossierImport,
                source: ImportSource(service: profile.dossierIdentity.service, accountID: profile.dossierIdentity.accountID),
                fetchedAt: profile.observedAt, contactID: contactID))
        guard case .linked(let id) = result?.value else { return nil }
        return id
    }
    func linkMailSender(_ letter: MailLetter) async -> UUID? {
        guard MailAddress.isValid(letter.sender) else { return nil }
        let result = await perform(
            .link(
                letter.dossierContact, source: ImportSource(service: "mail", accountID: letter.key.accountID), fetchedAt: Date(),
                contactID: nil))
        guard case .linked(let id) = result?.value else { return nil }
        return id
    }
    func linkWhatsAppChat(_ chat: WhatsAppChat, accountID: UUID) async -> UUID? {
        guard let contact = chat.dossierContact else { return nil }
        let result = await perform(
            .link(contact, source: ImportSource(service: "whatsapp", accountID: accountID.uuidString), fetchedAt: Date(), contactID: nil))
        guard case .linked(let id) = result?.value else { return nil }
        return id
    }
    func linkTeamsPerson(_ person: TeamsPerson, accountID: UUID) async -> UUID? {
        guard let contact = try? await BackgroundWork.run({ person.dossierContact }) else {
            error = "Для привязки нужен подтверждённый профиль человека и его организация Teams."
            return nil
        }
        let result = await perform(
            .link(contact, source: ImportSource(service: "teams", accountID: accountID.uuidString), fetchedAt: Date(), contactID: nil))
        guard case let .linked(id) = result?.value else { return nil }
        return id
    }
    func openTelemostDossier(_ telemost: TelemostWorkspaceModel, contactID: UUID, while isCurrent: @MainActor () -> Bool) async -> UUID? {
        let context = telemost.contextID
        guard isCurrent(), let id = await telemost.openDossier(contactID: contactID), isCurrent(), context == telemost.contextID,
            await selectContact(id, while: { isCurrent() && context == telemost.contextID }),
            isCurrent(), context == telemost.contextID
        else { return nil }
        return id
    }
    func openTeamsDossier(_ person: TeamsPerson, accountID: UUID, while isCurrent: @MainActor () -> Bool) async -> UUID? {
        guard isCurrent(), let id = await linkTeamsPerson(person, accountID: accountID), isCurrent(),
            await selectContact(id, while: isCurrent), isCurrent()
        else { return nil }
        return id
    }
    func selectContact(_ id: UUID, while isCurrent: @MainActor () -> Bool = { true }) async -> Bool {
        guard ready, !busy, isCurrent() else { return false }
        let revision = selectionRevision
        busy = true
        defer { busy = false }
        do {
            let snapshot = try await worker.snapshot()
            guard isCurrent() else { return false }
            let selectionUnchanged = revision == selectionRevision
            publish(snapshot)
            guard snapshot.contacts.contains(where: { $0.id == id }) else {
                throw StoreError.invalid("Досье изменилось. Откройте карточку собеседника заново.")
            }
            guard selectionUnchanged else { return false }
            selectedID = id
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    private func publish(_ snapshot: ContactWorkspaceSnapshot) {
        contacts = snapshot.contacts
        duplicates = snapshot.duplicates
        merges = snapshot.merges
        if let selectedID, !contacts.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    private func perform(_ command: ContactWorkspaceCommand, selectResult: Bool = false) async -> ContactWorkspaceWriteResult? {
        guard canWrite else { return nil }
        let revision = selectionRevision
        busy = true
        error = nil
        defer { busy = false }
        do {
            let result = try await worker.apply(command)
            let selectionUnchanged = revision == selectionRevision
            if let snapshot = result.snapshot {
                publish(snapshot)
            } else {
                writesBlocked = true
                error =
                    "Изменения сохранены, но не удалось обновить отображение. Не повторяйте действие. Проверьте подключение к PostgreSQL и откройте приложение заново."
            }
            if selectResult, selectionUnchanged {
                switch result.value {
                case .saved(let id), .merged(let id): selectedID = id
                default: break
                }
            }
            return result
        } catch {
            if let failure = error as? ContactWorkspaceError, failure.blocksWrites { writesBlocked = true }
            self.error = error.localizedDescription
            return nil
        }
    }
    func addNote(_ text: String, contactID: UUID? = nil) async -> Bool {
        guard let id = contactID ?? selectedID else { return false }
        return await perform(.addNote(contactID: id, text: text)) != nil
    }
    func setAIAccess(_ access: AIContactAccess, contactID: UUID) async -> Bool {
        await perform(.setAIAccess(contactID: contactID, access: access)) != nil
    }
    func importFile(_ url: URL) async {
        guard let result = await perform(.importFile(url)), case .imported(let count) = result.value else { return }
        notice = "Импорт завершён: создано \(count.created), обновлено \(count.updated)."
    }
    func merge(_ candidate: DuplicateCandidate, survivor: UUID) async -> Bool {
        guard survivor == candidate.firstID || survivor == candidate.secondID else { return false }
        return await perform(
            .merge(
                survivorID: survivor,
                removedID: survivor == candidate.firstID ? candidate.secondID : candidate.firstID), selectResult: true) != nil
    }
    @discardableResult func undo(_ record: MergeRecord) async -> Bool { await perform(.undo(record.id)) != nil }
    func name(_ id: UUID) -> String { contacts.first { $0.id == id }?.displayName ?? "Контакт недоступен" }

}
