import AppKit
import Combine
import MakoshCalendar
import MakoshCore
import MakoshGoogle
import ServiceManagement
import SwiftUI

private struct CalendarHostKey: EnvironmentKey {
    static let defaultValue: CalendarHost? = nil
}

extension EnvironmentValues {
    var calendarHost: CalendarHost? {
        get { self[CalendarHostKey.self] }
        set { self[CalendarHostKey.self] = newValue }
    }
}

/// One calendar service per process, owned by the application delegate rather than a
/// window: polling, busy copies and reminders keep running with every window closed.
@MainActor final class CalendarHost: ObservableObject {
    nonisolated static let qaFlag = CalendarQAIsolation.flag
    @Published private(set) var model: CalendarWorkspaceModel?
    @Published private(set) var failure: String?
    /// An event to open, from a reminder click.
    @Published var openEventRequest: UUID?
    /// Moving a planner slot's event in the calendar moves the slot (set by the Tasks host).
    var slotMoved: ((UUID, Date, Date) async -> Void)?
    private(set) var service: CalendarService?
    private(set) var store: CalendarStore?
    private var configured = false
    let notifications = CalendarSystemNotifications()
    private let router: @MainActor () -> ApplicationSystemNotificationRouter?
    private let keychain: CalendarKeychainAccess
    /// The archive-vault key for sealed event fields; QA keeps a fixed synthetic key in memory.
    private let keyProvider: @Sendable (UUID, Bool) throws -> Data
    var usesSystemKeychain: Bool { synthetic == nil }
    private let synthetic: [String: CalendarSyntheticAdapter]?
    private var reminderTask: Task<Void, Never>?
    private var refreshObservation: AnyCancellable?

    /// The router is resolved at start, so creating the host touches no system notification state.
    init(router: @escaping @MainActor () -> ApplicationSystemNotificationRouter? = { nil }) {
        self.router = router
        keychain = .system
        keyProvider = MessageArchiveKeychain.open
        synthetic = nil
    }

    #if DEBUG
    /// Isolated QA: synthetic servers by account name, an in-memory Keychain, no system notifications.
    init(synthetic adapters: [String: CalendarSyntheticAdapter]) {
        router = { nil }
        keychain = .memory()
        // Synthetic data only: no system Keychain prompt for an ad-hoc signed QA bundle.
        keyProvider = { _, _ in Data(repeating: 0x51, count: 32) }
        synthetic = adapters
    }
    #endif

    var googleClientID: String? { GoogleOAuthClient.embedded?.clientID }

    /// Mail accounts for the CalDAV hint (address and IMAP host); set by the workspace.
    var mailAccounts: [(email: String, imapHost: String)] = []
    /// Person e-mail addresses for attendee suggestions; set by the workspace.
    var contactEmails: [String] = []
    /// «Добавить Telemost» for a Yandex calendar; set by the workspace when a Telemost account exists.
    var telemostCreator: ((String) async -> URL?)?

    func contactSuggestions(for text: String) -> [String] {
        let typed = text.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard typed.count >= 2, !typed.contains("@") || !contactEmails.contains(typed) else { return [] }
        return Array(contactEmails.filter { $0.lowercased().contains(typed) }.prefix(4))
    }

    func canAddTelemost(collectionID: UUID?) -> Bool {
        guard telemostCreator != nil, let collectionID, let model, let collection = model.collection(collectionID),
            let account = model.snapshot?.accounts.first(where: { $0.id == collection.accountID }), account.kind == .caldav
        else { return false }
        return account.caldavServer?.host?.hasSuffix("yandex.ru") == true
    }

    func createTelemost(title: String) async -> URL? { await telemostCreator?(title) }

    /// Opens the store in the application schema and starts polling and reminders; safe to call once.
    func start(
        configuration: PersonWorkspaceConfiguration, taskFeed: (any CalendarTaskFeed)?,
        seed: ((CalendarStore, CalendarService) async throws -> Void)? = nil
    ) async {
        guard !configured else { return }
        configured = true
        let store = CalendarStore(connectionString: configuration.connectionString, schema: configuration.schema, keyProvider: keyProvider)
        let http = CalendarHTTP()
        let google =
            synthetic == nil
            ? GoogleOAuthClient.embedded.map { client in
                GoogleOAuth(
                    client: client, http: http.service, scopes: GoogleOAuth.calendarScopes,
                    openBrowser: { url in _Concurrency.Task { @MainActor in NSWorkspace.shared.open(url) } })
            } : nil
        let factory: CalendarService.AdapterFactory
        if let synthetic {
            factory = { account, _ in
                guard let adapter = synthetic[account.name] else { throw CalendarFailure.notFound }
                return adapter
            }
        } else {
            factory = CalendarService.defaultAdapterFactory(oauth: google, http: http)
        }
        let service = CalendarService(
            store: store, vault: CalendarCredentialVault(access: keychain), adapterFactory: factory, google: google)
        self.store = store
        self.service = service
        let model = CalendarWorkspaceModel(service: service)
        model.taskFeed = taskFeed
        self.model = model
        notifications.attach(router())
        notifications.open = { [weak self] id in self?.openEventRequest = id }
        do {
            try await service.open()
            if let seed { try await seed(store, service) }
            await model.refresh()
            if synthetic == nil { await service.startPolling() }
            startReminders()
        } catch {
            failure = "Раздел «Календарь» не открыл хранилище."
        }
    }

    /// Re-plans reminders every minute from a two-day snapshot.
    private func startReminders() {
        reminderTask?.cancel()
        reminderTask = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                await self?.planReminders()
                try? await _Concurrency.Task.sleep(for: .seconds(60))
            }
        }
    }

    func planReminders() async {
        guard let service else { return }
        let now = Date()
        guard let snapshot = try? await service.snapshot(window: DateInterval(start: now.addingTimeInterval(-3600), duration: 2 * 86400))
        else {
            return
        }
        await notifications.reschedule(CalendarReminderPlanner.reminders(snapshot: snapshot, now: now), now: now)
    }
}

/// «Открывать Makosh при входе» through the system login items.
@MainActor enum LoginItemSetting {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
