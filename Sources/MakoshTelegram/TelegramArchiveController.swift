import Foundation
import Combine
import MakoshCore
import SwiftSignalKit

struct TelegramArchiveJournalItem: Sendable {
    let sequence: Int64
    let observations: [MessageArchiveObservation]
}
enum TelegramArchiveReadError: Error { case corrupt }
@MainActor protocol TelegramArchiveJournal: AnyObject {
    var accountID: Int64 { get }
    func read(receive: @escaping @MainActor (Result<[TelegramArchiveJournalItem], TelegramArchiveReadError>) -> Void) -> Disposable
    func acknowledge(sequences: [Int64], receive: @escaping @MainActor (Bool) -> Void) -> Disposable
}
protocol TelegramArchiveRepository: Actor {
    func append(_ observations: [MessageArchiveObservation]) async throws -> Int
    func records(before: Int64?) async throws -> [MessageArchiveRecord]
}

private actor TelegramPostgresArchiveRepository: TelegramArchiveRepository {
    private let connectionString: String
    private let schema: String
    private var store: MessageArchiveStore?
    init(connectionString: String, schema: String) { self.connectionString = connectionString; self.schema = schema }
    private func open() throws -> MessageArchiveStore {
        if let store { return store }
        let result = try MessageArchiveStore(connectionString: connectionString, schema: schema,
                                             keyProvider: MessageArchiveKeychain.open)
        store = result
        return result
    }
    func append(_ observations: [MessageArchiveObservation]) throws -> Int {
        do { return try open().append(observations) }
        catch { store = nil; throw error }
    }
    func records(before: Int64?) throws -> [MessageArchiveRecord] {
        do { return try open().records(before: before, limit: 100) }
        catch { store = nil; throw error }
    }
}

/// A source journal is acknowledged only after the independent archive commits.
/// UI dismissal/account switches never cancel already accepted archive writes.
@MainActor public final class TelegramArchiveController: ObservableObject {
    public let files = TelegramFileArchiveController()
    @Published public private(set) var records: [MessageArchiveRecord] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isArchiving = false
    @Published public private(set) var canLoadMore = false
    @Published public private(set) var error: String?
    @Published public private(set) var status = "Локальный архив не открыт"
    @Published public private(set) var isSynthetic = false
    @Published public private(set) var usesSyntheticS3 = false
    private var repository: (any TelegramArchiveRepository)?
    private var journal: (any TelegramArchiveJournal)?
    private var binding = UUID()
    private var reading = false
    private var readToken = UUID()
    private var writing = false
    private var readOperation = MetaDisposable()
    private var ackOperation = MetaDisposable()
    private var poll: Task<Void, Never>?
    private var pageTask: Task<Void, Never>?
    private var pageToken = UUID()
    var pollDelay: Duration = .seconds(1)

    public init() {}

    #if DEBUG
    /// Explicit local-only QA: synthetic text plus an isolated S3/PG file fixture.
    public func configureSyntheticS3(connectionString: String,schema: String,configurationFile: URL,spoolDirectory: URL) throws {
        guard schema.hasPrefix("makosh_qa_"), repository == nil else { throw MessageArchiveError.invalid }
        configure(repository: TelegramSyntheticArchiveRepository(includeFile: true),synthetic: true)
        try files.configureSynthetic(connectionString: connectionString,schema: schema,configurationFile: configurationFile,spoolDirectory: spoolDirectory)
        usesSyntheticS3 = true
        let directory = spoolDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true,attributes: [.posixPermissions: 0o700])
        let source = directory.appendingPathComponent("synthetic-cache-\(UUID().uuidString)")
        let bytes = Data("Makosh synthetic file retained in S3 after Telegram cache removal.\n".utf8)
        try bytes.write(to: source,options: .withoutOverwriting)
        files.accept(file: source,byteCount: Int64(bytes.count),identity: MessageArchiveIdentity(service: "telegram",accountID: "-1",conversationID: "1",messageID: "0:9001"),
            attachment: MessageArchiveAttachment(id: "synthetic-s3-file",kind: "file",name: "synthetic-retained.txt",size: Int64(bytes.count)))
        try FileManager.default.removeItem(at: source)
    }
    #endif

    /// Composition supplies configuration, without connecting or accessing Keychain.
    public func configure(connectionString: String, schema: String) {
        guard repository == nil else { return }
        repository = TelegramPostgresArchiveRepository(connectionString: connectionString, schema: schema)
    }

    func configure(repository: any TelegramArchiveRepository, synthetic: Bool = false) {
        guard self.repository == nil else { return }
        self.repository = repository; isSynthetic = synthetic
        if synthetic { status = "Синтетический архив: оригинал, правка и удаление из источника" }
    }

    func bind(journal: (any TelegramArchiveJournal)?) {
        binding = UUID(); readToken = UUID(); poll?.cancel(); poll = nil
        readOperation.set(nil); ackOperation.set(nil)
        reading = false; self.journal = journal
        // A PostgreSQL write already in progress owns its immutable account DTO.
        // Wait for it to finish before starting another source read.
        if journal != nil { drain() }
        else if !writing { isArchiving = false }
    }

    public func retry() { error = nil; drain(); reload() }

    public func reload() {
        pageToken = UUID(); pageTask?.cancel(); pageTask = nil
        loadPage(before: nil)
    }

    public func loadOlder() {
        guard !isLoading, canLoadMore, let before = records.last?.sequence else { return }
        loadPage(before: before)
    }

    private func loadPage(before: Int64?) {
        guard let repository else {
            error = "Хранилище архива не настроено. Проверьте подключение к PostgreSQL."
            return
        }
        let token = UUID(); pageToken = token; isLoading = true
        pageTask = Task { [weak self] in
            do {
                let page = try await repository.records(before: before)
                guard let self, self.pageToken == token, !Task.isCancelled else { return }
                if before == nil { self.records = page } else { self.records += page }
                self.canLoadMore = page.count == 100; self.isLoading = false
                self.pageTask = nil
            } catch {
                guard let self, self.pageToken == token, !Task.isCancelled else { return }
                self.isLoading = false; self.pageTask = nil
                self.error = "Не удалось открыть зашифрованный архив. Проверьте PostgreSQL и доступ к ключу в Связке ключей. Существующие данные не заменены."
            }
        }
    }

    func drain() {
        guard let journal, let repository, !reading, !writing else {
            if journal != nil, repository == nil { error = "Архив не настроен: сообщения пока остаются в журнале Telegram." }
            return
        }
        poll?.cancel(); poll = nil
        let token = binding
        let operation = UUID(); readToken = operation
        reading = true; isArchiving = true
        let returned = journal.read { [weak self] result in
            guard let self, self.binding == token, self.readToken == operation, self.reading else { return }
            self.reading = false
            switch result {
            case .failure:
                self.isArchiving = false
                self.error = "Не удалось прочитать журнал сохранения Telegram. Записи не подтверждены и не удалены."
            case let .success(items):
                guard !items.isEmpty else {
                    self.isArchiving = false; self.status = "Полученные сообщения сохраняются отдельно от Telegram"
                    self.schedulePoll(token: token); return
                }
                guard items.count <= 100, Set(items.map(\.sequence)).count == items.count,
                      items.allSatisfy({ !$0.observations.isEmpty && $0.observations.count <= 2
                          && $0.observations.allSatisfy({ $0.identity.service == "telegram"
                              && $0.identity.accountID.utf8.elementsEqual(String(journal.accountID).utf8) }) }) else {
                    self.isArchiving = false; self.error = "Журнал архива имеет неверную область аккаунта. Записи не подтверждены."
                    return
                }
                self.writing = true
                Task { [weak self] in
                    do {
                        _ = try await repository.append(items.flatMap(\.observations))
                        guard let self else { return }
                        self.writing = false
                        guard self.binding == token else { self.drain(); return }
                        self.acknowledge(items: items, journal: journal, token: token)
                    } catch {
                        guard let self else { return }
                        self.writing = false; self.isArchiving = false
                        self.error = "Архив ещё не записан в PostgreSQL. Журнал Telegram сохранён; повторите запись после восстановления хранилища."
                        if self.binding != token { self.drain() }
                    }
                }
            }
        }
        // The callback may run synchronously; a completed read needs no live lease.
        if reading, binding == token { readOperation.set(returned) } else { returned.dispose() }
    }

    private func acknowledge(items: [TelegramArchiveJournalItem], journal: any TelegramArchiveJournal, token: UUID) {
        let operation = UUID(); readToken = operation
        reading = true
        let returned = journal.acknowledge(sequences: items.map(\.sequence)) { [weak self] succeeded in
            guard let self, self.binding == token, self.readToken == operation, self.reading else { return }
            self.reading = false; self.isArchiving = false
            guard succeeded else {
                self.error = "Копия сохранена в архиве, но подтверждение журнала Telegram не завершено. Повторная запись безопасна."
                return
            }
            self.status = "Сообщения сохранены в независимом архиве"
            self.error = nil
            self.schedulePoll(token: token, immediate: true)
        }
        if reading, binding == token { ackOperation.set(returned) } else { returned.dispose() }
    }

    private func schedulePoll(token: UUID, immediate: Bool = false) {
        poll?.cancel()
        let delay: Duration = immediate ? .milliseconds(10) : pollDelay
        poll = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.binding == token else { return }
            self.poll = nil; self.drain()
        }
    }

    isolated deinit {
        poll?.cancel(); pageTask?.cancel()
        readOperation.dispose(); ackOperation.dispose()
    }
}
