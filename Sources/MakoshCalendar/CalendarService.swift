import Foundation

/// The calendar section's service: accounts, polling, busy copies and user
/// commands. Protocol, SQL and Keychain work run here, never on the main actor.
public actor CalendarService {
    public typealias AdapterFactory = @Sendable (CalendarAccount, CalendarCredentialVault) async throws -> any CalendarAdapter

    public let store: CalendarStore
    let vault: CalendarCredentialVault
    let adapterFactory: AdapterFactory
    let google: GoogleOAuth?
    let now: @Sendable () -> Date
    var adapters: [UUID: any CalendarAdapter] = [:]
    var lastSync: [UUID: Date] = [:]
    var pausedUntil: [UUID: Date] = [:]
    var syncing = Set<UUID>()
    var pollTask: Task<Void, Never>?

    public init(
        store: CalendarStore, vault: CalendarCredentialVault, adapterFactory: @escaping AdapterFactory, google: GoogleOAuth?,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.vault = vault
        self.adapterFactory = adapterFactory
        self.google = google
        self.now = now
    }

    public static func defaultAdapterFactory(oauth: GoogleOAuth?, http: CalendarHTTP) -> AdapterFactory {
        { account, vault in
            switch account.kind {
            case .google:
                guard let oauth, let subject = account.googleGrantID, let grant = try await vault.grant(subject: subject) else {
                    throw CalendarFailure.signInRequired
                }
                return GoogleCalendarAdapter(grant: grant, oauth: oauth, http: http)
            case .caldav:
                guard let server = account.caldavServer, let login = account.caldavLogin,
                    let password = try await vault.password(accountID: account.id)
                else { throw CalendarFailure.signInRequired }
                return CalDAVAdapter(server: server, login: login, password: password, http: http)
            case .subscription:
                guard let url = account.subscriptionURL else { throw CalendarFailure.invalidInput("subscription url") }
                return try SubscriptionAdapter(url: url, http: http)
            case .local:
                throw CalendarFailure.invalidInput("local calendar has no server")
            }
        }
    }

    public func open() async throws {
        try await store.open()
        _ = try await store.localAccount()
    }

    public func close() async {
        stopPolling()
        await store.close()
    }

    // MARK: Snapshot

    public func snapshot(window: DateInterval) async throws -> CalendarSnapshot {
        let accounts = try await store.accounts(), collections = try await store.collections(), groups = try await store.groups()
        let events = try await store.events(
            collectionIDs: Set(collections.map(\.id)), from: window.start, to: window.end, includeCopies: true)
        let occurrences = CalendarExpansion.occurrences(events, in: window)
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let stale = Set(
            collections.filter { collection in
                accounts.first { $0.id == collection.accountID }.map { [.needsSignIn, .adminBlocked, .unreachable].contains($0.state) }
                    ?? false
            }.map(\.id))
        return CalendarSnapshot(
            accounts: accounts, collections: collections, groups: groups, occurrences: occurrences, events: byID,
            openAttempts: try await store.openAttempts(),
            externalConflicts: Self.externalConflicts(occurrences: occurrences, events: byID, collections: collections, now: now()),
            staleCollectionIDs: stale, window: window, googleAvailable: google != nil, preferences: try await store.preferences())
    }

    static func externalConflicts(
        occurrences: [CalendarOccurrence], events: [UUID: CalendarEvent], collections: [CalendarCollection], now: Date
    )
        -> [CalendarConflict]
    {
        var found: [String: CalendarConflict] = [:]
        for occurrence in occurrences where occurrence.end > now {
            guard let event = events[occurrence.eventID], event.givesBusy else { continue }
            let own = event.masterID ?? event.id
            for conflict in CalendarConflictFinder.conflicts(
                start: occurrence.start, end: occurrence.end, collectionID: occurrence.collectionID, excluding: event.id,
                occurrences: occurrences, events: events, collections: collections)
            {
                let other = events[conflict.eventID]
                if let source = other?.busyMarker?.sourceEventID, source == event.id || source == own { continue }
                if other?.masterID == own || conflict.eventID == own { continue }
                found[conflict.id] = conflict
            }
        }
        return found.values.sorted { $0.start < $1.start }
    }

    // MARK: Accounts

    public func addCalDAVAccount(name: String, server: URL, login: String, password: String) async throws -> CalendarAccount {
        guard server.scheme == "https", server.host != nil else { throw CalendarFailure.invalidInput("https required") }
        var account = CalendarAccount(kind: .caldav, name: name, caldavServer: server, caldavLogin: login)
        try await vault.savePassword(password, accountID: account.id)
        do {
            let adapter = try await adapterFactory(account, vault)
            let remote = try await adapter.collections()
            account.serverSchedules = await adapter.schedulesInvitations
            try await store.saveAccount(account)
            adapters[account.id] = adapter
            try await merge(remote, accountID: account.id)
        } catch {
            try? await vault.removePassword(accountID: account.id)
            throw error
        }
        await sync(accountID: account.id)
        return try await self.account(account.id)
    }

    public func addSubscription(name: String, url: URL) async throws -> CalendarAccount {
        let normalized = try SubscriptionAdapter(url: url, http: CalendarHTTP()).url
        let account = CalendarAccount(kind: .subscription, name: name, subscriptionURL: normalized)
        let adapter = try await adapterFactory(account, vault)
        let remote = try await adapter.collections()
        try await store.saveAccount(account)
        adapters[account.id] = adapter
        try await merge(
            remote.map { RemoteCollection(externalID: $0.externalID, name: name, color: $0.color, access: .read) }, accountID: account.id)
        await sync(accountID: account.id)
        return try await self.account(account.id)
    }

    public func addGoogleAccount(loginHint: String?) async throws -> CalendarAccount {
        guard let google else { throw CalendarFailure.invalidInput("google not configured") }
        let grant = try await google.signIn(loginHint: loginHint)
        try await vault.saveGrant(grant)
        var account =
            try await store.accounts().first { $0.kind == .google && $0.googleGrantID == grant.subject }
            ?? CalendarAccount(kind: .google, name: grant.email, googleGrantID: grant.subject)
        account.state = .connected
        account.lastError = nil
        try await store.saveAccount(account)
        adapters[account.id] = nil
        try await refreshCollections(accountID: account.id)
        await sync(accountID: account.id)
        return try await self.account(account.id)
    }

    /// Signs the same Google account in again after a revoked or expired grant.
    public func reauthorize(accountID: UUID) async throws {
        var account = try await account(accountID)
        guard account.kind == .google, let google else { throw CalendarFailure.invalidInput("not a google account") }
        let grant = try await google.signIn(loginHint: account.name)
        guard grant.subject == account.googleGrantID else { throw CalendarFailure.invalidInput("other account") }
        try await vault.saveGrant(grant)
        account.state = .connected
        account.lastError = nil
        try await store.saveAccount(account)
        adapters[accountID] = nil
        pausedUntil[accountID] = nil
        await sync(accountID: accountID)
    }

    /// Takes the account's calendars out of every group so their busy copies go
    /// while access remains, then disables the account and forgets its secrets.
    public func disconnect(accountID: UUID) async throws {
        let account = try await account(accountID)
        for var collection in try await store.collections() where collection.accountID == accountID {
            collection.groupIDs = []
            try await store.saveCollection(collection)
        }
        await reconcileBusy(read: [])
        try await store.removeAccount(id: accountID)
        switch account.kind {
        case .google:
            let others = try await store.accounts().contains {
                $0.id != accountID && $0.googleGrantID == account.googleGrantID && $0.state != .disabled
            }
            if let subject = account.googleGrantID, !others {
                try await vault.removeGrant(subject: subject)
                await google?.forget(subject: subject)
            }
        case .caldav: try await vault.removePassword(accountID: accountID)
        case .local, .subscription: break
        }
        adapters[accountID] = nil
    }

    public func refreshCollections(accountID: UUID) async throws {
        let adapter = try await adapter(for: account(accountID))
        try await merge(try await adapter.collections(), accountID: accountID)
    }

    func merge(_ remote: [RemoteCollection], accountID: UUID) async throws {
        let existing = try await store.collections().filter { $0.accountID == accountID }
        for item in remote {
            if var current = existing.first(where: { $0.externalID == item.externalID }) {
                current.name = item.name
                current.access = item.access
                try await store.saveCollection(current)
            } else {
                try await store.saveCollection(
                    CalendarCollection(
                        accountID: accountID, externalID: item.externalID, name: item.name, color: item.color ?? "#8b5cf6",
                        access: item.access,
                        defaultReminderMinutes: try await store.preferences().defaultReminderMinutes))
            }
        }
    }

    func account(_ id: UUID) async throws -> CalendarAccount {
        guard let account = try await store.accounts().first(where: { $0.id == id }) else { throw CalendarFailure.notFound }
        return account
    }

    func adapter(for account: CalendarAccount) async throws -> any CalendarAdapter {
        if let cached = adapters[account.id] { return cached }
        let adapter = try await adapterFactory(account, vault)
        adapters[account.id] = adapter
        return adapter
    }

    // MARK: Sync

    public func syncAll() async {
        guard let accounts = try? await store.accounts() else { return }
        await withTaskGroup(of: Void.self) { group in
            for account in accounts where account.kind != .local && account.state != .disabled {
                group.addTask { await self.sync(accountID: account.id) }
            }
        }
        await reconcileBusy(read: [])
    }

    /// Syncs the accounts whose interval has passed; signed-out and blocked ones wait for the user.
    public func syncDue() async {
        guard let accounts = try? await store.accounts(), let preferences = try? await store.preferences() else { return }
        let moment = now()
        var due: [UUID] = []
        for account in accounts where account.kind != .local && ![.disabled, .needsSignIn, .adminBlocked].contains(account.state) {
            if let paused = pausedUntil[account.id], paused > moment { continue }
            let interval = TimeInterval(account.kind == .subscription ? preferences.subscriptionPollSeconds : preferences.pollSeconds)
            if let last = lastSync[account.id], moment.timeIntervalSince(last) < interval { continue }
            due.append(account.id)
        }
        await withTaskGroup(of: Void.self) { group in
            for id in due { group.addTask { await self.sync(accountID: id) } }
        }
    }

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncDue()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func sync(accountID: UUID) async {
        guard !syncing.contains(accountID), var account = try? await account(accountID), account.kind != .local, account.state != .disabled
        else { return }
        syncing.insert(accountID)
        defer { syncing.remove(accountID) }
        lastSync[accountID] = now()
        var read = Set<UUID>()
        do {
            let adapter = try await adapter(for: account)
            let preferences = try await store.preferences()
            let window = DateInterval(start: now(), duration: TimeInterval(preferences.horizonDays) * 86400)
            for collection in try await store.collections()
            where collection.accountID == accountID && (collection.shown || !collection.groupIDs.isEmpty) {
                let changes = try await adapter.changes(
                    collection: collection, cursor: try await store.cursor(collectionID: collection.id), window: window)
                try await apply(changes, to: collection, window: window)
                read.insert(collection.id)
            }
            account.state = .connected
            account.lastError = nil
            pausedUntil[accountID] = nil
        } catch let error as CalendarHTTPError {
            if case .retryAfter(let seconds) = error { pausedUntil[accountID] = now().addingTimeInterval(seconds) }
            account.state = .unreachable
            account.lastError = error.failure
        } catch let failure as CalendarFailure {
            account.state = Self.state(after: failure)
            account.lastError = failure
            if account.state == .needsSignIn { adapters[accountID] = nil }
        } catch {
            account.state = .unreachable
            account.lastError = .unreachable
        }
        try? await store.saveAccount(account)
        await reconcileBusy(read: read)
    }

    static func state(after failure: CalendarFailure) -> CalendarAccountState {
        switch failure {
        case .signInRequired, .rejected(code: 401, _): .needsSignIn
        case .adminBlocked: .adminBlocked
        default: .unreachable
        }
    }

    func apply(_ changes: RemoteChangeSet, to collection: CalendarCollection, window: DateInterval) async throws {
        let ordered = changes.events.filter { $0.recurrenceID == nil } + changes.events.filter { $0.recurrenceID != nil }
        try await store.performInTransaction { store in
            for var event in ordered where event.externalID != nil {
                if event.recurrenceID != nil {
                    event.masterID = try store.events(uid: event.uid, collectionID: collection.id).first { $0.recurrenceID == nil }?.id
                }
                try store.observe(event, collectionID: collection.id)
            }
            for id in changes.removedExternalIDs { try store.observeRemoval(resource: id, collectionID: collection.id) }
            if changes.full {
                // Absent from a full read and within the read window: gone on the server.
                let present = Set(changes.events.compactMap(\.externalID))
                let horizon = window.start.addingTimeInterval(-30 * 86400)
                for event in try store.liveEvents(collectionID: collection.id) {
                    guard let id = event.externalID, !present.contains(id) else { continue }
                    let end = CalendarOccurrence(eventID: event.id, collectionID: collection.id, time: event.time, key: Date()).end
                    if event.recurrence != nil || end > horizon { try store.observeRemoval(externalID: id, collectionID: collection.id) }
                }
            }
            try store.saveCursor(changes.cursor, collectionID: collection.id)
        }
    }
}
