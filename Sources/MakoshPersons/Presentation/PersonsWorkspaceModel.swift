import Combine
import Foundation
import MakoshCore
import MakoshGoogle

/// One book's view of one person: its card entry, an open attempt, and why it is blocked.
package struct PersonBookRow: Equatable, Sendable {
    package let book: PersonBook
    package let entry: PersonBookEntry?
    package let attempt: PersonAttempt?
    package let blocked: PersonsFailure?
}

/// The Persons section's state on the main actor; persons come from the core worker,
/// books and cards from `PersonsService`. No SQL and no network run here.
@MainActor package final class PersonsWorkspaceModel: ObservableObject {
    package let service: PersonsService
    package let persons: PersonWorkspaceWorker

    @Published package private(set) var snapshot: PersonsSnapshot?
    @Published package private(set) var tree: [PersonsTreeNode] = []
    @Published package private(set) var summaries: [PersonSummary] = []
    @Published package private(set) var organizations: [PersonSummary] = []
    @Published package private(set) var memberships: [PersonMembership] = []
    @Published package private(set) var filter: PersonsFilter = .all
    @Published package private(set) var search = ""
    @Published package var selectedID: UUID?
    @Published package var error: String?
    @Published package var notice: String?
    @Published package private(set) var busy = false
    private var expanded: Set<UUID> = []
    private var preferencesLoaded = false

    package init(service: PersonsService, persons: PersonWorkspaceWorker) {
        self.service = service
        self.persons = persons
    }

    // MARK: Loading

    package func load() async {
        if !preferencesLoaded, let preferences = try? await service.store.preferences() {
            expanded = preferences.expandedOrganizations
            filter = PersonsFilter(rawValue: preferences.filter) ?? .all
            preferencesLoaded = true
        }
        await refresh()
    }

    package func refresh() async {
        busy = true
        defer { busy = false }
        do {
            let snapshot = try await service.snapshot()
            let all = try await persons.summaries(matching: "", limit: 2000)
            let matched = search.isEmpty ? all : try await persons.summaries(matching: search, limit: 2000)
            let memberships = try await persons.allMembershipsForPresentation()
            self.snapshot = snapshot
            self.memberships = memberships
            organizations = all.filter { $0.kind == .organization }
            summaries = matched
            rebuild()
        } catch {
            self.error = Self.describe(error)
        }
    }

    private func rebuild() {
        guard let snapshot else { return }
        let suggested = Set(memberships.filter { $0.state == .suggested }.map(\.personID))
        tree = PersonsTree.build(
            summaries: summaries, organizations: organizations, memberships: memberships, expanded: expanded, filter: filter,
            blocked: Set(snapshot.blocked.keys), suggestedPersonIDs: suggested, search: search)
    }

    // MARK: Filter, search, tree

    package func setFilter(_ value: PersonsFilter) {
        filter = value
        rebuild()
        Task { [service] in
            var preferences = (try? await service.store.preferences()) ?? PersonsPreferences()
            preferences.filter = value.rawValue
            try? await service.store.savePreferences(preferences)
        }
    }

    package func setSearch(_ text: String) { search = text }

    package func toggleExpanded(organizationID: UUID) {
        if expanded.contains(organizationID) { expanded.remove(organizationID) } else { expanded.insert(organizationID) }
        rebuild()
        let snapshotExpanded = expanded
        Task { [service] in
            var preferences = (try? await service.store.preferences()) ?? PersonsPreferences()
            preferences.expandedOrganizations = snapshotExpanded
            try? await service.store.savePreferences(preferences)
        }
    }

    package func isExpanded(_ organizationID: UUID) -> Bool { expanded.contains(organizationID) }

    // MARK: Per person

    /// Every writable book against this person: entry, open attempt and blocking reason.
    package func bookStates(for personID: UUID) -> [PersonBookRow] {
        guard let snapshot else { return [] }
        return snapshot.books.filter { $0.kind.isBook && $0.acceptsAddressBook }.map { book in
            PersonBookRow(
                book: book, entry: snapshot.entries.first { $0.personID == personID && $0.bookID == book.id && $0.state != .removed },
                attempt: snapshot.openAttempts.first { $0.personID == personID && $0.bookID == book.id },
                blocked: snapshot.blocked[personID]?[book.id])
        }
    }

    package func mailCount(address: String) async -> Int {
        (try? await persons.mailEvidence(address: address).clean) ?? 0
    }

    // MARK: Commands

    private func perform(_ body: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await body()
            await refresh()
        } catch {
            self.error = Self.describe(error)
        }
    }

    package func setAddressBook(personID: UUID, on: Bool) async {
        await perform {
            _ = try await persons.apply(.setAddressBook(personID: personID, on: on))
            await service.requestWritePass()
        }
    }

    package func deleteEverywhere(personID: UUID) async {
        await perform { _ = try await service.deleteEverywhere(personID: personID) }
    }

    package func settle(bookID: UUID) async { await perform { try await service.settleUnknown(bookID: bookID) } }

    package func dismiss(attemptID: UUID) async { await perform { try await service.dismissAttempt(id: attemptID) } }

    package func resend(entryID: UUID) async { await perform { try await service.resend(entryID: entryID) } }

    package func deleteDuplicate(entryID: UUID) async { await perform { try await service.deleteDuplicateEntry(id: entryID) } }

    package func mergePersons(survivorID: UUID, removedID: UUID) async {
        await perform { try await service.mergePersons(survivorID: survivorID, removedID: removedID) }
    }

    package func undoMerge(id: UUID) async { await perform { try await service.undoMerge(id: id) } }

    package func readAll() async { await perform { await service.readAll() } }

    package func removeBook(id: UUID) async { await perform { try await service.removeBook(id: id) } }

    package func reconnect(bookID: UUID) async { await perform { try await service.reconnect(id: bookID) } }

    package func setBookOptions(
        id: UUID, readBook: Bool? = nil, isAddressBookSource: Bool? = nil, acceptsAddressBook: Bool? = nil,
        collectConversations: Bool? = nil
    ) async {
        await perform {
            try await service.setBookOptions(
                id: id, readBook: readBook, isAddressBookSource: isAddressBookSource, acceptsAddressBook: acceptsAddressBook,
                collectConversations: collectConversations)
        }
    }

    package func savePreferences(_ preferences: PersonsPreferences) async {
        await perform { try await service.store.savePreferences(preferences) }
    }

    package static func describe(_ error: Error) -> String {
        switch error {
        case let failure as PersonsFailure:
            switch failure {
            case .signInRequired: "Нужен повторный вход в учётную запись."
            case .noAccess: "Нет доступа к книге. Разрешите доступ и повторите."
            case .unreachable: "Сервер книги недоступен."
            case .notFound: "Запись не найдена."
            case .preconditionFailed: "Карточка изменилась снаружи; Makosh перечитает её при следующем проходе."
            case .noPhoneOrPeer: "Для Telegram нужен телефон или знакомый собеседник."
            case .notInTelegram: "В Telegram нет аккаунта с таким телефоном."
            case .rejected(let code, _): "Сервер отклонил запрос (код \(code))."
            case .unknownOutcome: "Результат неизвестен: проверьте позже, не повторяя действие."
            case .retryAfter(let seconds): "Сервер просит подождать \(seconds) с."
            case .invalidInput(let what): "Неверные данные: \(what)."
            case .storage, .invalidSchema, .notOpen: "Хранилище раздела недоступно."
            }
        default: error.localizedDescription
        }
    }
}
