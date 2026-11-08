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
    var reconcileTask: Task<Void, Never>?
    var reconcileAgain = false
    var pendingRead = Set<UUID>()
    var lastCollectionRefresh: [UUID: Date] = [:]

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
        // Passes are capped per calendar: repeat until nothing involving this account is left or nothing moves.
        let own = Set(try await store.collections().filter { $0.accountID == accountID }.map(\.id))
        var remaining = Int.max
        for _ in 0..<40 {
            await reconcileBusy(read: [])
            let records = try await store.busyCopies(targetCollectionID: nil)
            let left = records.count + (records.contains { own.contains($0.targetCollectionID) } ? 1 : 0)
            if left == 0 || left >= remaining { break }
            remaining = left
        }
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
        lastCollectionRefresh[accountID] = now()
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
        guard !syncing.contains(accountID), let account = try? await account(accountID), account.kind != .local, account.state != .disabled
        else { return }
        syncing.insert(accountID)
        defer { syncing.remove(accountID) }
        lastSync[accountID] = now()
        var read = Set<UUID>()
        var state = CalendarAccountState.connected
        var failure: CalendarFailure?
        do {
            let adapter = try await adapter(for: account)
            // Calendars created, shared or removed on the server show up at most an hour later.
            if now().timeIntervalSince(lastCollectionRefresh[accountID] ?? .distantPast) > 3600 {
                try await merge(try await adapter.collections(), accountID: accountID)
            }
            let preferences = try await store.preferences()
            let window = DateInterval(start: now(), duration: TimeInterval(preferences.horizonDays) * 86400)
            for collection in try await store.collections()
            where collection.accountID == accountID && (collection.shown || !collection.groupIDs.isEmpty) {
                do {
                    let changes = try await adapter.changes(
                        collection: collection, cursor: try await store.cursor(collectionID: collection.id), window: window)
                    try await apply(changes, to: collection, window: window)
                    read.insert(collection.id)
                } catch CalendarFailure.rejected(let code, _) where [403, 404, 410].contains(code) {
                    // One calendar deleted or unshared on the server must not starve the others.
                    continue
                }
            }
            pausedUntil[accountID] = nil
        } catch let error as CalendarHTTPError {
            if case .retryAfter(let seconds) = error { pausedUntil[accountID] = now().addingTimeInterval(seconds) }
            state = .unreachable
            failure = error.failure
        } catch let known as CalendarFailure {
            state = Self.state(after: known)
            failure = known
            if state == .needsSignIn { adapters[accountID] = nil }
        } catch {
            state = .unreachable
            failure = .unreachable
        }
        // Only the connection state is ours to write: a rename or a disconnect made meanwhile stays.
        if var current = try? await self.account(accountID), current.state != .disabled {
            current.state = state
            current.lastError = failure
            try? await store.saveAccount(current)
        }
        await reconcileBusy(read: read)
    }

    /// Every busy pass goes through this one runner: requests coalesce (their read sets
    /// merge) and passes never overlap, so no pass judges another's write in flight.
    func reconcileSoon(read: Set<UUID> = []) {
        pendingRead.formUnion(read)
        guard reconcileTask == nil else {
            reconcileAgain = true
            return
        }
        reconcileTask = Task {
            repeat {
                reconcileAgain = false
                let batch = pendingRead
                pendingRead = []
                await runReconcilePass(read: batch)
            } while reconcileAgain
            reconcileTask = nil
        }
    }

    /// A pass through the runner, awaited.
    public func reconcileBusy(read: Set<UUID>) async {
        reconcileSoon(read: read)
        await settled()
    }

    /// Waits until background busy-copy work has finished.
    public func settled() async {
        while let task = reconcileTask { await task.value }
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
                    let current =
                        event.recurrence == nil
                        ? end > horizon
                        : !CalendarRecurrenceExpander.occurrences(
                            of: event, overrides: [], in: DateInterval(start: horizon, end: max(window.end, horizon))
                        ).isEmpty
                    if current { try store.observeRemoval(externalID: id, collectionID: collection.id) }
                }
            }
            try store.saveCursor(changes.cursor, collectionID: collection.id)
        }
    }
}

extension CalendarService {
    /// Appearance and reminder settings of a calendar; groups change only through the group preview.
    public func updateCollection(_ collection: CalendarCollection) async throws {
        guard let current = try await store.collections().first(where: { $0.id == collection.id }) else { throw CalendarFailure.notFound }
        var value = collection
        value.groupIDs = current.groupIDs
        value.access = current.access
        value.externalID = current.externalID
        value.accountID = current.accountID
        try await store.saveCollection(value)
    }

    /// Name and working hours; connection fields stay as they are (a new server is a new account).
    public func updateAccount(_ account: CalendarAccount) async throws {
        guard var current = try await store.accounts().first(where: { $0.id == account.id }) else { throw CalendarFailure.notFound }
        current.name = account.name
        current.workingHours = account.workingHours
        try await store.saveAccount(current)
    }

    public func savePreferences(_ preferences: CalendarPreferences) async throws {
        try await store.savePreferences(preferences)
    }
}
