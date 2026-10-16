import Combine
import Foundation
import MakoshCore
import MakoshTeams

struct TeamsMessageRow: Identifiable, Sendable {
    let id: Int64
    let message: TeamsMessage
    let text: String
}

@MainActor final class TeamsWorkspaceModel: ObservableObject {
    @Published private(set) var accounts: [TeamsAccount] = []
    @Published private(set) var selectedAccountID: UUID?
    @Published private(set) var selectedScope: TeamsScope?
    @Published private(set) var snapshot: TeamsWorkspaceSnapshot?
    @Published private(set) var messages: [TeamsMessage] = []
    @Published private(set) var rows: [TeamsMessageRow] = []
    @Published private(set) var hasOlder = false
    @Published private(set) var historyBusy = false
    @Published private(set) var busy = false
    @Published private(set) var filesAvailable = false
    @Published private(set) var authorization: TeamsAuthorizationPresentation?
    @Published private(set) var notificationEvents: [TeamsNotificationEvent] = []
    @Published private(set) var notificationActivation: UUID?
    @Published private(set) var unread: [TeamsScope: Int] = [:]
    @Published var error: String?
    @Published var fileError: String?
    @Published var searchQuery = ""
    let worker: any TeamsServing
    let composer: TeamsComposerModel
    let isSynthetic: Bool
    private let polling: Bool
    private let storageFile: URL?
    private let spool: URL?
    private var loaded = false, loading = false
    private var accountGeneration: UInt64 = 0, selectionGeneration: UInt64 = 0
    private var cursor: TeamsRetainedCursor?
    private var pollTask: Task<Void, Never>?
    private var refreshID: UUID?
    var historyExtended: Bool { rows.count > 50 }
    var notificationWorker: any TeamsNotificationServing { worker }
    var selectedAccount: TeamsAccount? { accounts.first { $0.id == selectedAccountID } }
    var chats: [TeamsConversation] { snapshot?.chats ?? [] }
    var title: String {
        guard let selectedScope else { return "Microsoft Teams" }
        if let chat = chats.first(where: { $0.scope == selectedScope }) { return chat.displayName }
        switch selectedScope.resource {
        case let .channel(team, channel), let .thread(team, channel, _):
            return snapshot?.channels.first { $0.teamID == team && $0.id == channel }?.displayName ?? "Канал"
        case .chat: return "Беседа"
        }
    }
    var canSend: Bool {
        guard let scope = selectedScope, selectedAccount?.readOnly == false, (snapshot?.state == .connected || (isSynthetic && snapshot?.state == .synthetic)) else { return false }
        if case .chat = scope.resource { return snapshot?.capabilities.contains(.sendChat) == true }
        return snapshot?.capabilities.contains(.sendChannel) == true
    }
    convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Makosh")
        let args = CommandLine.arguments
        let file = args.firstIndex(of: "--storage-config").flatMap { args.indices.contains($0 + 1) && !args[$0 + 1].hasPrefix("--") ? URL(fileURLWithPath: args[$0 + 1]) : nil } ?? support.appendingPathComponent("s3.json")
        self.init(worker: TeamsWorker(), polling: true, storageFile: file, spool: support.appendingPathComponent("TeamsFileQueue"))
    }
    init(worker: any TeamsServing, polling: Bool, synthetic: Bool = false, storageFile: URL? = nil, spool: URL? = nil) {
        self.worker = worker; self.polling = polling; isSynthetic = synthetic; self.storageFile = storageFile; self.spool = spool
        composer = TeamsComposerModel(worker: worker, synthetic: synthetic)
    }
    deinit { pollTask?.cancel(); let worker = worker; Task { await worker.shutdown() } }
    func load(configuration: ContactWorkspaceConfiguration) async {
        guard !loaded, !loading else { return }
        if isSynthetic {
            let args = CommandLine.arguments
            let admitted = (try? await BackgroundWork.run { TeamsSyntheticLaunchPolicy.admits(arguments: args, configuration: configuration) }) == true
            guard admitted else { error = "Нужны отдельные схемы qa_teams_ и локальная конфигурация Teams QA."; return }
        }
        loading = true; defer { loading = false }
        do {
            accounts = try await worker.load(configuration: configuration)
            if isSynthetic { for account in accounts { try await worker.connect(accountID: account.id) } }
            if let storageFile, let spool {
                do {
                    let storage = try await BackgroundWork.run { try S3ConfigurationFile.read(storageFile) }
                    try await worker.configureFiles(storage: storage, spoolDirectory: spool); filesAvailable = true
                } catch { fileError = "Не удалось открыть настройки S3. Переписка доступна, подготовка файлов пока выключена." }
            } else if isSynthetic { fileError = "Для файлов в QA нужны --storage-config и --teams-qa-spool." }
            loaded = true
            if let first = accounts.first { await selectAccount(first.id) }
            if polling {
                pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.refresh()
                        do { try await Task.sleep(for: .seconds(1)) } catch { break }
                    }
                }
            }
        } catch { self.error = teamsFailureMessage(error) }
    }
    func addAccount(name: String, clientID: String, authority: String, readOnly: Bool) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let configuration = TeamsOAuthConfiguration(clientID: clientID, authority: authority)
            let account = try await worker.addAccount(name: name, configuration: configuration, readOnly: readOnly)
            accounts.append(account); await selectAccount(account.id)
        } catch { self.error = teamsFailureMessage(error) }
    }
    func selectAccount(_ id: UUID) async {
        guard accounts.contains(where: { $0.id == id }) else { return }
        let previous = selectedAccountID
        let wasAuthorizing = authorization != nil
        accountGeneration &+= 1; selectionGeneration &+= 1
        let token = accountGeneration
        selectedAccountID = id; selectedScope = nil; snapshot = nil; messages = []; rows = []; unread = [:]
        authorization = nil; cursor = nil; hasOlder = false; historyBusy = false; busy = false; searchQuery = ""; error = nil
        composer.setContext(nil)
        do {
            if wasAuthorizing, let previous { try await worker.cancelAuthorization(accountID: previous) }
            guard token == accountGeneration else { return }
            let value = try await worker.snapshot(accountID: id)
            guard token == accountGeneration else { return }; snapshot = value
        } catch { if token == accountGeneration { self.error = teamsFailureMessage(error) } }
    }
    func selectConversation(_ scope: TeamsScope) async {
        guard scope.accountID == selectedAccountID, snapshot?.principal?.tenantID == scope.tenantID else { return }
        selectionGeneration &+= 1
        selectedScope = scope; messages = []; rows = []; cursor = nil; hasOlder = false; historyBusy = false; searchQuery = ""
        composer.setContext(scope)
        await loadHistory(reset: true)
        guard selectedScope == scope else { return }
        await markLocallyRead()
    }
    func openThread(_ message: TeamsMessage) async {
        guard let scope = selectedScope, message.scope == scope, case let .channel(team, channel) = scope.resource else { return }
        await selectConversation(TeamsScope(accountID: scope.accountID, tenantID: scope.tenantID, resource: .thread(teamID: team, channelID: channel, rootID: message.id)))
    }
    func openParentChannel() async {
        guard let scope = selectedScope, scope.policyScope != scope else { return }; await selectConversation(scope.policyScope)
    }
    func loadHistory(reset: Bool) async {
        guard let scope = selectedScope, !historyBusy, reset || hasOlder else { return }
        let token = selectionGeneration, query = searchQuery
        historyBusy = true; defer { if token == selectionGeneration { historyBusy = false } }
        do {
            let page: TeamsRetainedPage
            if query.isEmpty { page = try await worker.messages(scope: scope, before: reset ? nil : cursor) }
            else { page = try await worker.search(scope: scope, query: query, before: reset ? nil : cursor) }
            guard token == selectionGeneration else { return }
            let projected = try await BackgroundWork.run {
                zip(page.versionSequences, page.values).map { TeamsMessageRow(id: $0.0, message: $0.1, text: TeamsTextProjection.plain($0.1.body, contentType: $0.1.contentType)) }
            }
            guard token == selectionGeneration else { return }
            messages = reset ? page.values : messages + page.values; rows = reset ? projected : rows + projected
            cursor = page.next; hasOlder = page.next != nil
        } catch { if token == selectionGeneration { self.error = teamsFailureMessage(error) } }
    }
    func showLatest() async { await loadHistory(reset: true) }
    func search() async {
        selectionGeneration &+= 1; historyBusy = false; cursor = nil; hasOlder = false; messages = []; rows = []
        await loadHistory(reset: true)
    }
    func connect() async {
        guard let account = selectedAccountID, !busy else { return }
        let token = accountGeneration; busy = true
        defer { if token == accountGeneration { busy = false } }
        do { try await worker.connect(accountID: account); guard token == accountGeneration else { return }; await refresh() }
        catch { if token == accountGeneration { self.error = teamsFailureMessage(error) } }
    }
    func disconnect() async {
        guard let account = selectedAccountID else { return }
        accountGeneration &+= 1; let token = accountGeneration
        do { try await worker.disconnect(accountID: account); guard token == accountGeneration else { return }; authorization = nil; await refresh() }
        catch { if token == accountGeneration { self.error = teamsFailureMessage(error) } }
    }
    func authorize(method: TeamsAuthorizationMethod, capabilities: Set<TeamsCapability>) async {
        guard let account = selectedAccountID, !isSynthetic else { return }
        let token = accountGeneration; authorization = .pending
        do {
            let value = try await worker.beginAuthorization(accountID: account, method: method, capabilities: capabilities)
            guard token == accountGeneration else { return }; authorization = value
        } catch { if token == accountGeneration { self.error = teamsFailureMessage(error) } }
    }
    func cancelAuthorization() async {
        guard let account = selectedAccountID else { return }
        let token = accountGeneration
        do { try await worker.cancelAuthorization(accountID: account); guard token == accountGeneration else { return }; authorization = .cancelled; await refresh() }
        catch { if token == accountGeneration { self.error = teamsFailureMessage(error) } }
    }
    func synchronize() async {
        guard let account = selectedAccountID, !busy else { return }
        let token = accountGeneration; busy = true
        defer { if token == accountGeneration { busy = false } }
        do { try await worker.synchronize(accountID: account); guard token == accountGeneration else { return }; await refresh() }
        catch { if token == accountGeneration { self.error = teamsFailureMessage(error) } }
    }
    func refresh() async {
        guard loaded, refreshID == nil, let account = selectedAccountID else { return }
        let id = UUID(), token = accountGeneration; refreshID = id
        defer { if refreshID == id { refreshID = nil } }
        do {
            let value = try await worker.snapshot(accountID: account)
            guard token == accountGeneration else { return }; snapshot = value
            if let principal = value.principal, let index = accounts.firstIndex(where: { $0.id == account }) {
                let old = accounts[index]; accounts[index] = TeamsAccount(id: old.id, name: old.name, clientID: old.clientID, authority: old.authority, verifiedPrincipal: principal, readOnly: old.readOnly)
            }
            if authorization != nil {
                let presentation = try await worker.authorizationStatus(accountID: account)
                guard token == accountGeneration else { return }; authorization = presentation
            }
            var events: [TeamsNotificationEvent] = []
            for source in accounts.map(\.id) {
                events += try await worker.claimNotifications(accountID: source)
                guard token == accountGeneration else { return }
            }
            if !events.isEmpty { notificationEvents = events }
            for chat in value.chats {
                let count = try await worker.localUnreadCount(scope: chat.scope)
                guard token == accountGeneration else { return }; unread[chat.scope] = count
            }
            if selectedScope != nil, !historyBusy, !historyExtended, searchQuery.isEmpty { await loadHistory(reset: true) }
        } catch { if token == accountGeneration { self.error = teamsFailureMessage(error) } }
    }
    func markLocallyRead() async {
        guard let scope = selectedScope else { return }; let token = selectionGeneration
        do { try await worker.markLocallyRead(scope: scope); guard token == selectionGeneration else { return }; unread[scope.policyScope] = 0 }
        catch { if token == selectionGeneration { self.error = teamsFailureMessage(error) } }
    }
    func openNotification(_ event: TeamsNotificationEvent) async {
        await selectAccount(event.scope.accountID)
        guard selectedAccountID == event.scope.accountID else { return }
        await selectConversation(event.scope)
        guard selectedScope == event.scope else { return }; notificationActivation = UUID()
    }
    func shutdown() async {
        accountGeneration &+= 1; selectionGeneration &+= 1; pollTask?.cancel(); composer.setContext(nil)
        await worker.shutdown()
    }
}
