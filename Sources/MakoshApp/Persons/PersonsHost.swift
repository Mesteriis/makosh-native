import AppKit
import Combine
import Foundation
import MakoshCore
import MakoshGoogle
import MakoshPersons
import SwiftUI

private struct PersonsHostKey: EnvironmentKey {
    static let defaultValue: PersonsHost? = nil
}

extension EnvironmentValues {
    var personsHost: PersonsHost? {
        get { self[PersonsHostKey.self] }
        set { self[PersonsHostKey.self] = newValue }
    }
}

/// One Persons service per process, owned by the application delegate: books keep
/// polling and cards keep flowing with every window closed. Channels hand their
/// observations here; the Telegram engine answers through `telegramBridge`.
@MainActor final class PersonsHost: ObservableObject {
    nonisolated static let qaFlag = PersonsQAIsolation.flag
    @Published private(set) var model: PersonsWorkspaceModel?
    @Published private(set) var failure: String?
    private(set) var service: PersonsService?
    /// Set by the workspace once a Telegram model exists; nil keeps Telegram books unreachable.
    var telegramBridge: (any TelegramContactsBridge)?
    /// Mail accounts the workspace knows, for the CardDAV sheet's server hint.
    @Published var mailAccounts: [(email: String, imapHost: String)] = []
    private var configured = false
    private let keychain: KeychainAccess
    private let synthetic: [String: PersonSyntheticBook]?
    private var collectedLetterIDs = Set<String>()
    private var collectedPeers = Set<String>()

    init() {
        keychain = .system
        synthetic = nil
    }

    #if DEBUG
    /// Isolated QA: synthetic books by account id, an in-memory Keychain, no Telegram and no macOS Contacts.
    init(synthetic books: [String: PersonSyntheticBook]) {
        keychain = .memory()
        synthetic = books
    }
    #endif

    var isSynthetic: Bool { synthetic != nil }
    var googleClientID: String? { GoogleOAuthClient.embedded?.clientID }

    /// Opens the section's store on the dossier's configuration; the worker is the dossier's own.
    func configure(
        configuration: PersonWorkspaceConfiguration, worker: PersonWorkspaceWorker, seed: ((PersonsService) async throws -> Void)? = nil
    ) async {
        guard !configured else { return }
        configured = true
        let store = PersonsStore(connectionString: configuration.connectionString, schema: configuration.schema)
        let http = PersonsHTTP()
        let google =
            synthetic == nil
            ? GoogleOAuthClient.embedded.map { client in
                GoogleOAuth(
                    client: client, http: http.service, scopes: GoogleOAuth.contactsScopes,
                    openBrowser: { url in Task { @MainActor in NSWorkspace.shared.open(url) } })
            } : nil
        let grants = GoogleGrantVault(access: keychain)
        do {
            // The section's own core connection: the collector and the runner serialize with the
            // dossier worker through PostgreSQL's advisory lock.
            let persons = try await BackgroundWork.run {
                try PersonStore(connectionString: configuration.connectionString, schema: configuration.schema)
            }
            let service = PersonsService(
                persons: persons, store: store, vault: PersonsCredentialVault(access: keychain),
                adapterFactory: adapterFactory(http: http, google: google, grants: grants), google: google, grants: grants, http: http)
            self.service = service
            let model = PersonsWorkspaceModel(service: service, persons: worker)
            self.model = model
            try await service.open()
            if let seed { try await seed(service) }
            await model.load()
            if synthetic == nil { await service.startPolling() }
        } catch {
            failure = "Раздел «Персоны» не открыл хранилище."
        }
    }

    private func adapterFactory(http: PersonsHTTP, google: GoogleOAuth?, grants: GoogleGrantVault) -> PersonsService.AdapterFactory {
        let synthetic = synthetic
        let bridge = { @MainActor [weak self] in self?.telegramBridge }
        return { book, vault in
            if let synthetic {
                guard let adapter = synthetic[book.accountID] else { throw PersonsFailure.notFound }
                return adapter
            }
            switch book.kind {
            case .synthetic: throw PersonsFailure.notFound
            case .telegram:
                guard let bridge = await bridge() else { throw PersonsFailure.unreachable }
                return TelegramBookAdapter(accountID: book.accountID, bridge: bridge)
            case .carddav:
                guard let collection = book.caldavServer, let login = book.caldavLogin,
                    let password = try await vault.password(bookID: book.id)
                else { throw PersonsFailure.signInRequired }
                return CardDAVAdapter(collection: collection, login: login, password: password, http: http)
            case .googleContacts:
                guard let google, let subject = book.googleSubject, let grant = try await grants.grant(subject: subject),
                    grant.has(scope: GoogleOAuth.contactsScope)
                else { throw PersonsFailure.signInRequired }
                return GoogleContactsAdapter(grant: grant, oauth: google, http: http)
            case .macContacts:
                guard MacContactsAdapter.authorizationStatus == .authorized else { throw PersonsFailure.noAccess }
                return MacContactsAdapter()
            case .mail, .whatsapp, .teams: throw PersonsFailure.invalidInput("channel has no book")
            }
        }
    }

    // MARK: Channels

    /// Observations from a channel; letters are remembered so a republished list is not collected twice.
    func collect(_ observations: [PersonSourceObservation], spam: [MailEvidence] = []) async {
        guard let service else { return }
        _ = try? await service.collect(observations, spam: spam)
        await model?.refresh()
    }

    func markLetterCollected(_ id: String) -> Bool { collectedLetterIDs.insert(id).inserted }

    /// Dialog partners not yet profiled in this process; the account's contacts book covers the rest by polling.
    func newPeers(accountID: String, peerIDs: [Int64]) -> [Int64] {
        peerIDs.filter { collectedPeers.insert(accountID + ":" + String($0)).inserted }
    }

    /// The row for a channel account's «Собирать собеседников» switch; nil while the section is not open.
    @discardableResult
    func ensureChannelSource(kind: PersonBookKind, accountID: String, name: String) async -> PersonBook? {
        guard let service else { return nil }
        return try? await service.ensureChannelSource(kind: kind, accountID: accountID, name: name)
    }

    /// Whether conversations of this account are collected (the switch defaults to on).
    func collectsConversations(kind: PersonBookKind, accountID: String) async -> Bool {
        guard let service, let books = try? await service.store.books() else { return true }
        return books.first { $0.kind == kind && $0.accountID == accountID }?.collectConversations ?? true
    }
}
