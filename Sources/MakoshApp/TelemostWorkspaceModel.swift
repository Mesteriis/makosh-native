import AppKit
import Combine
import MakoshCore
import MakoshTelemost

/// Window-scoped conductor. Protocol, archive, keys and exports belong to the service.
@MainActor final class TelemostWorkspaceModel: ObservableObject {
    let service: any TelemostServing
    let isSynthetic: Bool
    let opener: @MainActor @Sendable (URL) -> Bool
    @Published var snapshot = TelemostWorkspaceSnapshot()
    @Published var selectedAccountID: UUID?
    @Published var selectedMeetingID: UUID?
    @Published var meetings: [TelemostLocalMeeting] = []
    @Published var contextID = UUID()
    @Published var ready = false
    @Published var busy = false
    @Published var hasMore = false
    @Published var history: [TelemostRetainedVersion] = []
    @Published var historyHasMore = false
    @Published var authorization: TelemostAuthorizationRequest?
    @Published var grant: TelemostGrantResult?
    @Published var error: String?
    @Published private(set) var lastPatchResult: TelemostOperation?
    @Published private(set) var lastOpenedURL: URL?
    @Published var notice: String?
    @Published var query = ""
    @Published var draft: TelemostCreateRequest? { didSet { draftRevision &+= 1 } }
    private var draftRevision: UInt64 = 0
    private var cursor: TelemostHistoryCursor?
    private var loading = false
    private var closed = false
    var accounts: [TelemostAccount] { snapshot.accounts }
    var selectedAccount: TelemostAccount? { accounts.first { $0.id == selectedAccountID } }
    var selectedMeeting: TelemostLocalMeeting? { meetings.first { $0.id == selectedMeetingID } }
    var connection: TelemostConnectionState { selectedAccountID.flatMap { snapshot.connections[$0] } ?? .disconnected }
    var operations: [TelemostOperation] { snapshot.operations.filter { $0.accountID == selectedAccountID } }
    func can(_ capability: TelemostCapability) -> Bool { selectedAccountID.flatMap { snapshot.grantedCapabilities[$0] }?.contains(capability) == true }
    init(service: any TelemostServing = TelemostWorker(), synthetic: Bool = false,
         opener: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.service = service; isSynthetic = synthetic; self.opener = opener
    }
    deinit { let service = service; Task { await service.close() } }
    func start(configuration: ContactWorkspaceConfiguration) async {
        guard !ready, !loading, !closed else { return }; loading = true; defer { loading = false }
        do { try await service.open(configuration: configuration); guard !closed else { return }
            snapshot = try await service.snapshot(); ready = true; await reload()
        } catch { fail(error) }
    }
    func refreshState() async {
        guard ready, !closed else { return }; let context = contextID
        do { let value = try await service.snapshot(); guard context == contextID, !closed else { return }; snapshot = value }
        catch { if context == contextID, !closed { fail(error) } }
    }
    func close() async { closed = true; invalidateAuthorizationContext(); await service.close() }
    private func fail(_ value: any Error) { error = (value as? TelemostFailure)?.localizedDescription ?? "Операция Телемоста не завершена. Проверьте сохранённый статус." }
    func invalidateAuthorizationContext() {
        contextID = UUID(); busy = false; history = []; historyHasMore = false; lastPatchResult = nil; notice = nil; error = nil
        let old = authorization; authorization = nil; grant = nil
        if let old { let service = service; Task { await service.cancelAuthorization(id: old.id) } }
    }
    func selectAccount(_ id: UUID?) async {
        guard id == nil || accounts.contains(where: { $0.id == id }) else { return }
        invalidateAuthorizationContext(); selectedAccountID = id; selectedMeetingID = nil; meetings = []; query = ""; draft = nil; cursor = nil
        await reload()
    }
    func selectMeeting(_ id: UUID?) {
        guard id == nil || meetings.contains(where: { $0.id == id }) else { return }
        invalidateAuthorizationContext(); selectedMeetingID = id
    }
    func reload(more: Bool = false) async {
        guard ready, !closed else { return }; let context = contextID, account = selectedAccountID, search = query
        do {
            let page = try await service.page(accountID: account, query: search, before: more ? cursor : nil, limit: 50)
            guard context == contextID, search.utf8.elementsEqual(query.utf8), !closed else { return }
            meetings = more ? meetings + page.values.filter { value in !meetings.contains(where: { $0.id == value.id }) } : page.values
            cursor = page.next; hasMore = page.next != nil
            if let id = selectedMeetingID, !meetings.contains(where: { $0.id == id }) { selectMeeting(nil) }
            let value = try await service.snapshot(); guard context == contextID, !closed else { return }; snapshot = value
        } catch { if context == contextID, !closed { fail(error) } }
    }
    func authorizationCommand(_ action: @MainActor () async throws -> Void) async {
        guard ready, !busy, !closed else { return }; let context = contextID; busy = true; error = nil
        defer { if context == contextID { busy = false } }
        do { try await action() } catch { if context == contextID, !closed { fail(error) } }
    }
    func addAccount(name: String, clientID: String, capabilities: Set<TelemostCapability>) async {
        let account = TelemostAccount(name: name, clientID: clientID, callbackURL: URL(string: "org.makosh.desktop.telemost://oauth/callback")!, capabilities: capabilities)
        await authorizationCommand { try await service.addAccount(account); await reload() }
    }
    func addLink(_ text: String) async {
        let context = contextID, account = selectedAccountID
        await authorizationCommand {
            let url = try TelemostMeetingURL(text), id = try await service.addLink(url, accountID: account)
            guard context == contextID, !closed else { return }; query = ""; await reload()
            guard context == contextID else { return }; selectMeeting(id)
        }
    }
    func create(request: TelemostCreateRequest) async {
        guard let account = selectedAccountID else { return }
        let context = contextID, revision = draftRevision
        await authorizationCommand {
            let id = try await service.create(accountID: account, request: request)
            let value = try await service.snapshot()
            guard context == contextID, !closed else { return }; snapshot = value
            let state = value.operations.first { $0.id == id }?.state
            if state == .accepted, revision == draftRevision { draft = nil }
            notice = (isSynthetic ? "QA · подставной API. " : "") + (state == .accepted ? "API подтвердил создание встречи." : state == .unknown ? "Результат неизвестен. Повтор запрещён до явного решения в журнале операций." : "API отклонил создание. Черновик сохранён.")
            await reload()
        }
    }
    @discardableResult func update(patch: TelemostMeetingPatch) async -> Bool {
        guard let scope = selectedMeeting?.scope else { return false }; let context = contextID
        var accepted = false
        await authorizationCommand {
            let id = try await service.update(scope: scope, patch: patch)
            let value = try await service.snapshot()
            guard context == contextID, !closed else { return }
            guard let result = value.operations.first(where: { $0.id == id }) else { throw TelemostFailure.storage }
            snapshot = value; lastPatchResult = result; accepted = result.state == .accepted
            notice = (isSynthetic ? "QA · подставной API. " : "") + (accepted ? "API подтвердил изменение." : result.state == .unknown ? "Результат изменения неизвестен. Нужны GET и просмотр наблюдения в журнале; повтор заблокирован." : "API отклонил изменение. Выбранная настройка сохранена в редакторе.")
            await reload()
        }
        return accepted && context == contextID && !closed
    }
    func refreshSelected() async {
        guard let scope = selectedMeeting?.scope ?? selectedMeeting.flatMap({ meeting in meeting.accountID.map { TelemostScope(accountID: $0, conferenceID: meeting.validatedURL.conferenceID) } }) else { return }
        let context = contextID
        await authorizationCommand {
            var failure: (any Error)?
            do { try await service.refresh(scope: scope) } catch { failure = error }
            guard context == contextID, !closed else { return }
            await reload()
            guard context == contextID, !closed else { return }
            if let failure { throw failure }
        }
    }
    func saveLocal(_ value: TelemostLocalMeeting) async {
        guard value.id == selectedMeetingID, value.accountID == selectedAccountID else { return }; let context = contextID
        await authorizationCommand { try await service.saveLocal(value); guard context == contextID, !closed else { return }; await reload() }
    }
    func resolve(_ id: UUID, resolution: TelemostResolution) async {
        guard operations.contains(where: { $0.id == id && $0.state == .unknown }) else { return }; let context = contextID
        await authorizationCommand { try await service.resolve(operationID: id, resolution: resolution); guard context == contextID, !closed else { return }; await reload() }
    }
    func loadHistory(more: Bool = false) async {
        guard let id = selectedMeetingID else { return }; let context = contextID
        await authorizationCommand {
            let values = try await service.versions(meetingID: id, before: more ? history.last?.sequence : nil, limit: 50)
            guard context == contextID, !closed else { return }
            history = more ? history + values : values; historyHasMore = values.count == 50
        }
    }
    func exportHistory(to url: URL) async {
        let context = contextID, account = selectedAccountID
        await authorizationCommand { let count = try await service.export(accountID: account, to: url)
            guard context == contextID, !closed else { return }; notice = "Экспортировано версий: \(count). Файл содержит расшифрованные данные."
        }
    }
    func openMeeting(_ text: String) {
        do { let url = try TelemostMeetingURL(text); guard opener(url.url) else { throw TelemostFailure.invalidURL }
            lastOpenedURL = url.url
            notice = isSynthetic ? "QA: ссылка перехвачена, браузер не открыт: \(url.url.absoluteString)" : "Ссылка передана в официальный браузер или клиент. Участие проверяется там."
        } catch { fail(error) }
    }
    func openDossier(contactID: UUID) async -> UUID? {
        guard ready, !busy, !closed, let meeting = selectedMeetingID else { return nil }
        let context = contextID; busy = true; defer { if context == contextID { busy = false } }
        do { let owner = try await service.linkDossier(meetingID: meeting, contactID: contactID)
            guard context == contextID, !closed else { return nil }; return owner
        } catch { if context == contextID, !closed { fail(error) }; return nil }
    }
}
