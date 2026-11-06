import Foundation
import SwiftUI
import MakoshCore

@MainActor package final class MailWorkspaceModel: ObservableObject {
    @Published package private(set) var accounts: [MailAccount] = []
    private var autoConnect: MakoshAutoConnect?
    @Published package private(set) var folders: [MailFolder] = []
    @Published package private(set) var letters: [MailLetter] = []
    @Published package private(set) var drafts: [MailDraft] = []
    @Published package private(set) var submissions: [MailSubmission] = []
    @Published package private(set) var automation = MailAutomationState()
    @Published package var automationSettings = false
    @Published package var historyLetter: MailLetter?
    @Published package var selectedFolder: MailFolder?
    @Published package var selectedID: String?
    @Published package var search = ""
    @Published package var unreadOnly = false
    @Published package var starredOnly = false
    @Published package var showArchive = false
    @Published package var showDossier = false
    @Published package var error: String?
    @Published package var notice: String?
    @Published package var outboxSheet = false
    @Published package var editingAccount: MailAccount?
    @Published package var accountSheet = false
    @Published package var composer: MailDraft?
    /// Files for the next compose sheet; the sheet takes them once when it opens.
    @Published package private(set) var composerAttachments: [URL] = []
    @Published package private(set) var ready = false
    @Published package private(set) var busy = false
    @Published package private(set) var connected = Set<String>()
    @Published package private(set) var saveFiles = true
    @Published package var notificationSettingsScope: MailNotificationScope?
    @Published package private(set) var notificationActivation = UUID()
    package let notifications = MailNotificationController()
    private var notificationSnapshot = MailSnapshot()
    private var reloading = false, reloadRequested = false
    private var reloadWaiters: [CheckedContinuation<Void, any Error>] = []
    private var pendingNotificationActions: [(MailNotificationAction, MailNotificationEvent)] = []
    private var syntheticNotificationAccounts = Set<String>()
    private var notificationRecoveryAccounts = Set<String>()
    @Published private var openedLetter: MailLetter?
    private var repository: MailRepository?
    private var workers: [String: MailAccountWorker] = [:]
    private var configuration: ContactWorkspaceConfiguration?
    private var revision: UInt64 = 0
    private var cacheCursors: [String: Int64] = [:]
    private var watchTask: Task<Void, Never>?
    private var inboxWatches: [String: Task<Void, Never>] = [:]
    private var automationWatches: [String: Task<Void, Never>] = [:]
    private var accountGenerations: [String: UUID] = [:]
    private var changesObserver: NSObjectProtocol?
    private static let changed = Notification.Name("org.makosh.mail.workspaceChanged")
    isolated deinit {
        if let changesObserver { NotificationCenter.default.removeObserver(changesObserver) }
        watchTask?.cancel()
        inboxWatches.values.forEach { $0.cancel() }
        automationWatches.values.forEach { $0.cancel() }
        let services = Array(workers.values)
        Task { for worker in services { await worker.disconnect() } }
    }
    package let synthetic: Bool
    package init(synthetic: Bool = false) {
        self.synthetic = synthetic
        changesObserver = NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] event in
            guard let other = event.object as? MailWorkspaceModel else { return }
            MainActor.assumeIsolated {
                guard let self, other !== self, self.ready, self.synthetic == other.synthetic,
                    let a = self.configuration, let b = other.configuration,
                    a.connectionString == b.connectionString, a.schema == b.schema, a.archiveSchema == b.archiveSchema
                else { return }
                Task { [weak self] in
                    do { try await self?.reload() } catch { self?.error = error.localizedDescription }
                }
            }
        }
    }
    package var selected: MailLetter? {
        if let openedLetter, openedLetter.id == selectedID { return openedLetter }
        return letters.first { $0.id == selectedID }
    }
    package func versions(_ id: String, beforeSequence: Int64?) async throws -> [MailLetterVersion] {
        guard let repository else { throw MailFailure.storage }
        return try await repository.versions(id, beforeSequence: beforeSequence)
    }
    package var displayed: [MailLetter] {
        letters.filter { letter in
            let inScope =
                showArchive
                || (letter.key.accountID == selectedFolder?.accountID && letter.key.folder == selectedFolder?.path
                    && letter.removedFromSource != true
                    && (selectedFolder?.uidValidity == nil || letter.key.uidValidity == selectedFolder?.uidValidity))
            let matches =
                search.isEmpty
                || [letter.subject, letter.senderName, letter.sender, letter.text ?? ""].contains {
                    $0.localizedCaseInsensitiveContains(search)
                }
            return inScope && matches && (!unreadOnly || !letter.seen || letter.id == selectedID) && (!starredOnly || letter.flagged)
        }.sorted { $0.date > $1.date }
    }
    package func load(configuration: ContactWorkspaceConfiguration) async {
        guard !ready, !busy else { return }
        guard
            !synthetic
                || (configuration.schema.hasPrefix("qa_mail_")
                    && (configuration.archiveSchema ?? configuration.schema).hasPrefix("qa_mail_"))
        else {
            error = "Для почтовой QA нужны отдельные схемы qa_mail_."
            return
        }
        busy = true
        defer { finishBusy() }
        self.configuration = configuration
        let keyProvider: @Sendable (UUID, Bool) throws -> Data
        if synthetic { keyProvider = { _, _ in Data(repeating: 0x73, count: 32) } } else { keyProvider = MessageArchiveKeychain.open }
        let repository = MailRepository(configuration: configuration, keyProvider: keyProvider)
        self.repository = repository
        do {
            if synthetic { try await seed(repository) }
            notificationRecoveryAccounts = Set(try await repository.snapshot().accounts.map(\.id))
            if synthetic {
                let snapshot = try await repository.snapshot()
                for folder in snapshot.folders where folder.kind == .inbox {
                    let letters = snapshot.letters.filter { $0.key.accountID == folder.accountID && $0.key.folder == folder.path }
                    try await repository.savePage(
                        letters, folder: folder, uidValidity: folder.uidValidity ?? letters.first?.key.uidValidity ?? 42,
                        notifyIncoming: true)
                }
                syntheticNotificationAccounts = Set(snapshot.accounts.map(\.id))
            }
            try await reload()
            ready = true
            if !synthetic { reconnectRemembered(MakoshAutoConnect(scope: configuration.schema)) }
            if synthetic, let folder = folders.first(where: { $0.kind == .inbox }) ?? folders.first {
                selectedFolder = folder
                selectedID = displayed.first?.id
                if let selectedID { openedLetter = try await repository.letter(selectedID) }
            }
        } catch { self.error = error.localizedDescription }
    }
    package func add(_ account: MailAccount, imapPassword: String?, smtpPassword: String?) async {
        guard ready, !busy, !synthetic else { return }
        busy = true
        defer { finishBusy() }
        do {
            inboxWatches.removeValue(forKey: account.id)?.cancel()
            accountGenerations[account.id] = UUID()
            connected.remove(account.id)
            updateNotificationContext()
            if let previous = workers.removeValue(forKey: account.id) { await previous.disconnect() }
            let worker = try worker(account)
            _ = try await worker.connect(imapPassword: imapPassword, smtpPassword: smtpPassword)
            connected.insert(account.id)
            autoConnect?.remember("mail", account: account.id)
            try await reload()
            accountSheet = false
            startInboxWatching(account)
            if let folder = folders.first(where: { $0.accountID == account.id && $0.kind == .inbox }) { selectFolder(folder) }
        } catch { self.error = error.localizedDescription }
    }
    /// Accounts left connected at the last quit reconnect one after another
    /// once loading finishes; a failure keeps the account remembered.
    private func reconnectRemembered(_ store: MakoshAutoConnect) {
        autoConnect = store
        let remembered = store.remembered("mail")
        let targets = accounts.filter { remembered.contains($0.id) }
        guard !targets.isEmpty else { return }
        Task { [weak self] in
            for account in targets { await self?.connect(account) }
        }
    }
    package func connect(_ account: MailAccount) async {
        await run {
            _ = try await self.worker(account).connect()
            self.connected.insert(account.id)
            self.autoConnect?.remember("mail", account: account.id)
        }
        if connected.contains(account.id) { startInboxWatching(account) }
        if connected.contains(account.id), let folder = folders.first(where: { $0.accountID == account.id && $0.kind == .inbox }) {
            selectFolder(folder)
        }
    }
    package func disconnect(_ account: MailAccount) async {
        autoConnect?.forget("mail", account: account.id)
        if selectedFolder?.accountID == account.id {
            watchTask?.cancel()
            watchTask = nil
        }
        notificationRecoveryAccounts.remove(account.id)
        automationWatches.removeValue(forKey: account.id)?.cancel()
        inboxWatches.removeValue(forKey: account.id)?.cancel()
        accountGenerations[account.id] = UUID()
        connected.remove(account.id)
        syntheticNotificationAccounts.remove(account.id)
        revision &+= 1
        updateNotificationContext()
        await workers[account.id]?.disconnect()
    }
    package func selectArchive() {
        revision &+= 1
        showArchive = true
        selectedID = nil
        openedLetter = nil
        watchTask?.cancel()
        watchTask = nil
        cacheCursors.removeValue(forKey: "archive")
    }
    package func selectFolder(_ folder: MailFolder) {
        revision &+= 1
        selectedFolder = folder
        selectedID = nil
        showArchive = false
        search = ""
        watchTask?.cancel()
        watchTask = nil
        cacheCursors.removeValue(forKey: folder.id)
        Task {
            await loadCachedFolder(folder)
            guard selectedFolder?.id == folder.id, !showArchive else { return }
            if connected.contains(folder.accountID) { await refresh() }
            await filePolicy()
        }
        if connected.contains(folder.accountID) { startWatching(folder) }
    }
    package func loadCachedFolder(_ folder: MailFolder) async {
        guard let repository else { return }
        do {
            let page = try await repository.cachedPage(folder: folder, beforeSequence: nil, limit: 50)
            guard selectedFolder?.id == folder.id, !showArchive else { return }
            cacheCursors[folder.id] = page.compactMap(\.cacheSequence).min()
            mergeHeaders(page)
        } catch { self.error = error.localizedDescription }
    }
    package var actionFolder: MailFolder? {
        if let letter = selected {
            return folders.first { $0.accountID == letter.key.accountID && $0.path == letter.key.folder }
                ?? MailFolder(accountID: letter.key.accountID, path: letter.key.folder, kind: .other, uidValidity: letter.key.uidValidity)
        }
        return showArchive ? nil : selectedFolder
    }
    private func startInboxWatching(_ account: MailAccount) {
        startAutomation(account)
        guard let folder = folders.first(where: { $0.accountID == account.id && $0.kind == .inbox }), let worker = try? worker(account)
        else { return }
        inboxWatches.removeValue(forKey: account.id)?.cancel()
        let generation = UUID()
        accountGenerations[account.id] = generation
        inboxWatches[account.id] = Task { [weak self] in
            let updates = await worker.updates(folder: folder)
            for await event in updates {
                guard !Task.isCancelled, let self, self.accountGenerations[account.id] == generation else { return }
                switch event {
                case .updated:
                    do {
                        try await self.reload()
                        self.announceChange()
                    } catch { self.error = error.localizedDescription }
                case .offline:
                    self.connected.remove(account.id)
                    self.updateNotificationContext()
                }
            }
        }
    }
    private func startWatching(_ folder: MailFolder) {
        guard folder.kind != .inbox, let account = accounts.first(where: { $0.id == folder.accountID }), let worker = try? worker(account)
        else { return }
        watchTask = Task { [weak self] in
            let updates = await worker.updates(folder: folder)
            for await event in updates {
                guard !Task.isCancelled, let self, self.selectedFolder?.id == folder.id else { return }
                switch event {
                case .updated:
                    do {
                        try await self.reload()
                        self.announceChange()
                    } catch { self.error = error.localizedDescription }
                case .offline:
                    self.connected.remove(folder.accountID)
                    self.updateNotificationContext()
                }
            }
        }
    }
    package func refresh(older: Bool = false, serverSearch: Bool = false) async {
        if older, let repository {
            await run {
                let scope = self.showArchive ? "archive" : (self.selectedFolder?.id ?? "archive")
                let page = try await repository.cachedPage(
                    folder: self.showArchive ? nil : self.selectedFolder, beforeSequence: self.cacheCursors[scope], limit: 50)
                if let cursor = page.compactMap(\.cacheSequence).min() { self.cacheCursors[scope] = cursor }
                self.mergeHeaders(page)
                if page.isEmpty, let folder = self.selectedFolder, self.connected.contains(folder.accountID), !self.showArchive,
                    let account = self.accounts.first(where: { $0.id == folder.accountID })
                {
                    let received = try await self.worker(account).page(folder: folder, beforeUID: self.displayed.map(\.key.uid).min())
                    self.mergeHeaders(received)
                    let current = try await repository.snapshot().folders.first { $0.id == folder.id } ?? folder
                    let cached = try await repository.cachedPage(folder: current, beforeSequence: nil, limit: 50)
                    self.mergeHeaders(cached)
                } else if page.isEmpty {
                    self.notice = "Более старых сохранённых писем нет."
                }
            }
            return
        }
        guard let folder = selectedFolder, let account = accounts.first(where: { $0.id == folder.accountID }) else { return }
        await run {
            let page = try await self.worker(account).page(
                folder: folder, beforeUID: older ? self.displayed.map(\.key.uid).min() : nil, query: serverSearch ? self.search : "")
            self.mergeHeaders(page)
            if page.isEmpty { self.notice = older ? "Более старых писем нет." : "Папка обновлена." }
        }
    }
    package func select(_ id: String?) {
        revision &+= 1
        selectedID = id
        openedLetter = nil
        Task { await filePolicy() }
        guard let letter = selected, let repository else { return }
        let generation = revision
        Task {
            await run {
                if let cached = try await repository.letter(letter.id), cached.text != nil {
                    guard generation == self.revision else { return }
                    self.openedLetter = cached
                    if !cached.seen, self.connected.contains(cached.key.accountID),
                        let account = self.accounts.first(where: { $0.id == cached.key.accountID })
                    {
                        _ = try await self.worker(account).flag(cached, seen: true)
                    }
                    return
                }
                guard self.connected.contains(letter.key.accountID),
                    let account = self.accounts.first(where: { $0.id == letter.key.accountID })
                else { return }
                let body = try await self.worker(account).body(letter)
                guard generation == self.revision else { return }
                self.openedLetter = body
                if !body.seen { _ = try await self.worker(account).flag(body, seen: true) }
            }
        }
    }
    package func mark(seen: Bool? = nil, starred: Bool? = nil) async {
        guard let letter = selected, let account = accounts.first(where: { $0.id == letter.key.accountID }) else { return }
        await run { _ = try await self.worker(account).flag(letter, seen: seen, starred: starred) }
    }
    package func move(to folder: MailFolder) async {
        guard let letter = selected, let account = accounts.first(where: { $0.id == letter.key.accountID }) else { return }
        await run {
            try await self.worker(account).move(letter, to: folder)
            self.notice = "Перемещение подтверждено сервером. Сохранённая копия остаётся в архиве."
        }
    }
    package func filePolicy() async {
        guard let folder = actionFolder, let account = accounts.first(where: { $0.id == folder.accountID }), !synthetic else { return }
        do {
            let value = try await worker(account).fileSaving(folder: folder)
            if actionFolder?.id == folder.id { saveFiles = value }
        } catch { self.error = error.localizedDescription }
    }
    package func setFilePolicy(_ enabled: Bool) async {
        guard let folder = actionFolder, let account = accounts.first(where: { $0.id == folder.accountID }), !synthetic else { return }
        await run {
            try await self.worker(account).setFileSaving(folder: folder, enabled: enabled)
            if self.actionFolder?.id == folder.id { self.saveFiles = enabled }
        }
    }
    /// A new letter to an address with files already attached (forwarding a file).
    package func compose(to address: String, attachments: [URL]) {
        composerAttachments = []
        compose()
        guard var draft = composer else { return }
        draft.to = address
        composer = draft
        composerAttachments = attachments
    }

    package func takeComposerAttachments() -> [URL] {
        let value = composerAttachments
        composerAttachments = []
        return value
    }

    package func compose(reply: Bool = false, forward: Bool = false) {
        composerAttachments = []
        let accountID = (reply || forward) ? selected?.key.accountID : selectedFolder?.accountID
        guard let account = accounts.first(where: { $0.id == accountID }) ?? ((reply || forward) ? nil : accounts.first) else {
            accountSheet = true
            return
        }
        if let letter = selected, reply || forward {
            composer = MailDraft(
                accountID: account.id, to: reply ? letter.sender : "", subject: (reply ? "Re: " : "Fwd: ") + letter.subject,
                body: "\n\n— \(letter.sender), \(letter.date.formatted()) —\n" + (letter.text ?? ""),
                replyMessageID: reply ? letter.messageID : nil, sourceFolder: letter.key.folder)
        } else {
            composer = MailDraft(accountID: account.id, sourceFolder: selectedFolder?.path ?? "INBOX")
        }
        if let draft = composer { composer = MailComposition.insertingSignature(automation.signatures[account.id] ?? "", into: draft) }
    }
    private func startAutomation(_ account: MailAccount) {
        guard !synthetic, let worker = try? worker(account) else { return }
        automationWatches.removeValue(forKey: account.id)?.cancel()
        automationWatches[account.id] = Task { [weak self] in
            for await update in await worker.automationUpdates() {
                guard !Task.isCancelled, let self else { return }
                if case .failure(let error) = update { self.notice = "Почтовая автоматизация: " + error.localizedDescription }
                do {
                    try await self.reload()
                    self.announceChange()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    package func setSignature(accountID: String, text: String) async {
        await run { try await self.repository?.setSignature(accountID: accountID, text: text) }
    }
    package func saveTemplate(_ template: MailReplyTemplate) async { await run { try await self.repository?.saveTemplate(template) } }
    package func deleteTemplate(_ id: UUID) async { await run { try await self.repository?.deleteTemplate(id) } }
    package func saveIncomingRule(_ rule: MailIncomingRule) async { await run { try await self.repository?.saveIncomingRule(rule) } }
    package func deleteIncomingRule(_ id: UUID) async { await run { try await self.repository?.deleteIncomingRule(id) } }
    package func cancelSchedule(_ item: MailScheduledSend, edit: Bool = false) async {
        await run {
            try await self.repository?.cancelSchedule(item.id)
            if edit {
                self.outboxSheet = false
                self.composer = item.draft
            }
        }
    }
    package func resolveSchedule(_ item: MailScheduledSend, wasSent: Bool) async {
        await run { try await self.repository?.resolveSchedule(item.id, wasSent: wasSent) }
    }
    package func retryRule(_ item: MailRuleOperation, cancel: Bool = false) async {
        await run { try await self.repository?.retryRulePreparation(item.id, cancel: cancel) }
    }
    package func resolveRule(_ item: MailRuleOperation) async { await run { try await self.repository?.resolveRuleOperation(item.id) } }
    package func schedule(_ draft: MailDraft, files: [URL], at date: Date) async {
        await run {
            guard let repository = self.repository, let account = self.accounts.first(where: { $0.id == draft.accountID }) else {
                throw MailFailure.storage
            }
            let prepared: MailDraft
            if self.synthetic {
                guard files.isEmpty else { throw MailFailure.invalidInput }
                prepared = draft
            } else {
                prepared = try await self.worker(account).prepareDraft(draft, attachmentFiles: files)
            }
            _ = try await repository.schedule(prepared, at: date)
            self.composer = nil
            self.notice = "Отправка запланирована. Макош должен быть открыт, аккаунт подключён."
        }
    }
    package func save(_ draft: MailDraft, files: [URL] = []) async {
        await run {
            guard let repository = self.repository, let account = self.accounts.first(where: { $0.id == draft.accountID }) else {
                throw MailFailure.storage
            }
            if self.synthetic {
                guard files.isEmpty else { throw MailFailure.invalidInput }
                try await repository.saveDraft(draft)
            } else {
                let saved = try await self.worker(account).saveDraft(draft, attachmentFiles: files)
                self.notice =
                    saved.remoteSave?.state == .saved
                    ? "Черновик сохранён локально и на сервере."
                    : "Черновик сохранён локально. Для сохранения на сервере подключите аккаунт и сохраните его ещё раз."
            }
            if self.synthetic { self.notice = "Черновик сохранён локально." }
            self.composer = nil
        }
    }
    package func editRemoteDraft() async {
        guard let letter = selected, let account = accounts.first(where: { $0.id == letter.key.accountID }) else { return }
        let generation = revision
        await run {
            let draft = try await self.worker(account).editRemoteDraft(letter)
            if self.revision == generation { self.composer = draft }
        }
    }
    package func resolveDraftSave(_ draft: MailDraft, saved: Bool) async {
        await run {
            guard let repository = self.repository, let expected = draft.remoteSave else { throw MailFailure.storage }
            try await repository.updateDraftRemoteSave(
                draft.id, expected: expected, state: saved ? .userConfirmedSaved : .userConfirmedMissing)
        }
    }
    package func resolveUnknown(_ id: UUID, wasSent: Bool) async {
        await run {
            guard let repository = self.repository else { throw MailFailure.storage }
            try await repository.resolveUnknown(id, wasSent: wasSent)
        }
    }
    package func send(_ draft: MailDraft, files: [URL]) async -> Bool {
        guard !synthetic, !busy, let account = accounts.first(where: { $0.id == draft.accountID }) else { return false }
        busy = true
        defer { finishBusy() }
        do {
            let result = try await worker(account).send(draft, attachmentFiles: files)
            notice =
                result.sentCopySaved
                ? "SMTP-сервер принял письмо. Копия сохранена в Отправленных."
                : "SMTP-сервер принял письмо. Копия в Отправленных не подтверждена; повтор отправки отключён."
            try await reload()
            composer = nil
            return true
        } catch {
            self.error = error.localizedDescription
            try? await reload()
            return false
        }
    }
    /// The attachment bytes for another destination; no notice, errors propagate.
    package func exportAttachmentFile(_ attachment: MailAttachment, letter: MailLetter, to url: URL) async throws {
        guard let account = accounts.first(where: { $0.id == letter.key.accountID }) else { throw MailFailure.invalidInput }
        try await worker(account).exportAttachment(attachment, letter: letter, to: url)
    }
    package func export(_ attachment: MailAttachment, letter: MailLetter, to url: URL) async {
        guard let account = accounts.first(where: { $0.id == letter.key.accountID }) else { return }
        await run {
            try await self.worker(account).exportAttachment(attachment, letter: letter, to: url)
            self.notice = "Вложение сохранено."
        }
    }
    private func worker(_ account: MailAccount) throws -> MailAccountWorker {
        if let worker = workers[account.id] { return worker }
        guard let repository, let configuration else { throw MailFailure.storage }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Makosh")
        let args = CommandLine.arguments
        let storage: URL
        if let i = args.firstIndex(of: "--storage-config"), args.indices.contains(i + 1) {
            storage = URL(fileURLWithPath: args[i + 1])
        } else {
            storage = support.appendingPathComponent("s3.json")
        }
        let worker = MailAccountWorker(
            account: account, repository: repository, configuration: configuration, storageFile: storage,
            spool: support.appendingPathComponent("FileArchiveQueue"))
        workers[account.id] = worker
        return worker
    }
    package func reload() async throws {
        if reloading {
            reloadRequested = true
            return try await withCheckedThrowingContinuation { reloadWaiters.append($0) }
        }
        reloading = true
        do {
            var events: [MailNotificationEvent] = []
            repeat {
                reloadRequested = false
                events.append(contentsOf: try await reloadOnce())
                if events.count > 100 { events.removeFirst(events.count - 100) }
            } while reloadRequested
            for event in events where notificationAccounts.contains(event.key.accountID) { notifications.receive(event) }
            reloading = false
            let waiters = reloadWaiters
            reloadWaiters = []
            waiters.forEach { $0.resume() }
        } catch {
            reloading = false
            let waiters = reloadWaiters
            reloadWaiters = []
            waiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }
    private func reloadOnce() async throws -> [MailNotificationEvent] {
        guard let repository else { throw MailFailure.storage }
        let generations = accountGenerations
        for (id, worker) in workers {
            let active = await worker.isConnected
            guard generations[id] == accountGenerations[id], workers[id] === worker else { continue }
            if active { connected.insert(id) } else { connected.remove(id) }
        }
        let current = if let openedLetter { try await repository.letter(openedLetter.id) } else { nil as MailLetter? }
        let batch = try await repository.takeNotificationBatch(accountIDs: notificationAccounts)
        let snapshot = batch.snapshot
        if let current, current.id == selectedID { openedLetter = current }
        accounts = snapshot.accounts
        folders = snapshot.folders
        if let selectedFolder {
            self.selectedFolder = folders.first { $0.id == selectedFolder.id }
            if self.selectedFolder?.uidValidity != selectedFolder.uidValidity { cacheCursors.removeValue(forKey: selectedFolder.id) }
        }
        mergeHeaders(snapshot.letters)
        drafts = snapshot.drafts
        submissions = snapshot.submissions
        automation = snapshot.automation ?? .init()
        notificationSnapshot = snapshot
        updateNotificationContext()
        return batch.events
    }
    private func updateNotificationContext() {
        notifications.update(
            snapshot: notificationSnapshot, connected: notificationAccounts, recoveryAccounts: notificationRecoveryAccounts)
    }
    private var notificationAccounts: Set<String> { synthetic ? syntheticNotificationAccounts : connected }
    package func setNotificationRule(scope: MailNotificationScope, rule: MailNotificationRule?, showWhileActive: Bool? = nil) async {
        await run {
            guard let repository = self.repository else { throw MailFailure.storage }
            try await repository.setNotificationRule(scope: scope, rule: rule, showWhileActive: showWhileActive)
        }
    }
    package func handleNotificationAction(_ action: MailNotificationAction, event: MailNotificationEvent) async {
        guard ready, notifications.canActivate(identifier: event.id),
            let account = accounts.first(where: { $0.id == event.key.accountID }),
            let source = folders.first(where: {
                $0.accountID == account.id && $0.path == event.key.folder && $0.uidValidity == event.key.uidValidity
            }),
            let repository
        else { return }
        if busy {
            guard !pendingNotificationActions.contains(where: { $0.1.id == event.id }) else { return }
            guard pendingNotificationActions.count < 100 else {
                error = "Очередь действий заполнена. Откройте письмо из списка."
                return
            }
            pendingNotificationActions.append((action, event))
            notice = "Действие из уведомления выполнится после текущей операции."
            return
        }
        let context = accountGenerations[account.id]
        notificationActivation = UUID()
        if action == .open {
            guard (try? await repository.claimNotificationAction(event.id)) == true,
                notifications.canActivate(identifier: event.id), accountGenerations[account.id] == context
            else { return }
            showArchive = false
            search = ""
            unreadOnly = false
            starredOnly = false
            selectedFolder = source
            select(event.id)
            return
        }
        guard !synthetic,
            let target = folders.first(where: { $0.accountID == account.id && $0.kind == (action == .archive ? .archive : .trash) })
        else {
            error = synthetic ? "Синтетическая проверка не изменяет папки на сервере." : "Сервер не предоставил нужную папку."
            return
        }
        await run {
            guard var letter = try await repository.letter(event.id), letter.key == event.key,
                self.accountGenerations[account.id] == context
            else { return }
            let worker = try self.worker(account)
            if !self.connected.contains(account.id) {
                _ = try await worker.connect()
                guard self.accountGenerations[account.id] == context else { return }
                self.connected.insert(account.id)
            }
            if letter.text == nil { letter = try await worker.body(letter) }
            guard !Task.isCancelled, self.connected.contains(account.id), self.accountGenerations[account.id] == context,
                self.notifications.canActivate(identifier: event.id), try await repository.claimNotificationAction(event.id)
            else { return }
            try await worker.move(letter, to: target)
            self.notice = "Письмо перемещено. Сохранённая копия остаётся в архиве."
        }
        if connected.contains(account.id) { startInboxWatching(account) }
    }
    #if DEBUG
    package func simulateIncoming() async {
        guard synthetic, let repository, let account = accounts.first,
            syntheticNotificationAccounts.contains(account.id),
            let folder = folders.first(where: { $0.accountID == account.id && $0.kind == .inbox })
        else { return }
        await run {
            let next =
                (self.letters.filter { $0.key.accountID == account.id && $0.key.folder == folder.path }.map(\.key.uid).max() ?? 0) + 1
            let letter = MailLetter(
                key: .init(accountID: account.id, folder: folder.path, uidValidity: folder.uidValidity ?? 42, uid: next),
                subject: "Тестовое входящее · \(next)", senderName: "Команда Макоша", sender: "team@example.invalid",
                recipient: account.email, date: Date(),
                text: "Синтетическая проверка уведомления. Сеть и реальные аккаунты не используются.")
            try await repository.savePage([letter], folder: folder, uidValidity: letter.key.uidValidity, notifyIncoming: true)
        }
    }
    #endif
    private func mergeHeaders(_ values: [MailLetter]) {
        var byID = Dictionary(uniqueKeysWithValues: letters.map { ($0.id, $0) })
        for value in values { byID[value.id] = value }
        letters = Array(byID.values)
    }
    private func run(_ action: @MainActor () async throws -> Void) async {
        guard ready, !busy else { return }
        busy = true
        error = nil
        defer { finishBusy() }
        do {
            try await action()
            try await reload()
            announceChange()
        } catch {
            self.error = error.localizedDescription
            try? await reload()
        }
    }
    private func finishBusy() {
        busy = false
        let pending = pendingNotificationActions
        pendingNotificationActions = []
        guard !pending.isEmpty else { return }
        Task { [weak self] in
            for (action, event) in pending { await self?.handleNotificationAction(action, event: event) }
        }
    }
    private func announceChange() { NotificationCenter.default.post(name: Self.changed, object: self) }
    private func seed(_ repository: MailRepository) async throws {
        let snapshot = try await repository.snapshot()
        guard snapshot.accounts.isEmpty else { return }
        let account = MailAccount(
            id: "15500000-0000-4000-8000-000000000001", displayName: "Рабочая почта", email: "alex@example.test",
            imapHost: "imap.example.invalid", imapUsername: "alex@example.test", smtpHost: "smtp.example.invalid",
            smtpUsername: "alex@example.test")
        try await repository.saveAccount(account)
        let folders = [
            MailFolder(accountID: account.id, path: "INBOX", kind: .inbox), .init(accountID: account.id, path: "Sent", kind: .sent),
            .init(accountID: account.id, path: "Drafts", kind: .drafts), .init(accountID: account.id, path: "Archive", kind: .archive),
            .init(accountID: account.id, path: "Trash", kind: .trash),
        ]
        try await repository.saveFolders(folders, accountID: account.id)
        let now = Date()
        let body =
            "Алексей, добрый день!\n\nОтправляю материалы к нашей встрече. В документе — обновлённая структура проекта и вопросы для обсуждения. Посмотри, пожалуйста, раздел с этапами.\n\nЕсли всё подходит, подготовлю финальную версию.\n\nСпасибо,\nМария."
        // Synthetic attachment metadata only; no real files, provider or S3 access.
        let files: [MailAttachment] = [
            .init(id: "qa-plan", filename: "План проекта.pdf", mimeType: "application/pdf", byteCount: 1_800_000),
            .init(
                id: "qa-stages", filename: "Этапы.xlsx", mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                byteCount: 240_000),
        ]
        let rows: [(String, String, String, String)] = [
            (
                "Иван Кузнецов", "ivan@example.test", "Обновления по проекту",
                "Привет! Добавил последние правки в документ. Буду ждать твоих комментариев."
            ),
            (
                "Анна Никифорова", "anna@example.test", "Запрос на согласование",
                "Коллеги, пожалуйста, посмотрите и подтвердите возможность реализации."
            ),
            (
                "Дмитрий Крылов", "dmitry@example.test", "Результаты тестирования",
                "Привет! Отправляю результаты тестирования. Основные замечания в приложении."
            ),
            (
                "Елена Лебедева", "elena@example.test", "Встреча в понедельник",
                "Предлагаю обсудить планы на следующий спринт. Удобно в 11:00?"
            ),
            ("Сергей Белов", "sergey@example.test", "Доступы к стенду", "Подготовил инструкции для подключения к тестовой среде."),
            ("Наталья Волкова", "natalia@example.test", "Спасибо!", "Спасибо за помощь и оперативные ответы!"),
        ]
        var letters = [
            MailLetter(
                key: .init(accountID: account.id, folder: "INBOX", uidValidity: 42, uid: 7),
                subject: "Материалы встречи", senderName: "Мария Соколова", sender: "maria@example.test", recipient: account.email,
                date: now, text: body,
                html:
                    "<p>Алексей, добрый день!</p><p>Отправляю <strong>материалы к нашей встрече</strong>.</p><img src='https://example.invalid/tracking.png'>",
                attachments: files)
        ]
        for (index, row) in rows.enumerated() {
            letters.append(
                .init(
                    key: .init(accountID: account.id, folder: "INBOX", uidValidity: 42, uid: UInt32(6 - index)),
                    subject: row.2, senderName: row.0, sender: row.1, recipient: account.email,
                    date: now.addingTimeInterval(-Double(index + 1) * 3600), seen: index > 1, flagged: index == 2, text: row.3))
        }
        try await repository.saveLetters(letters)
    }
}
