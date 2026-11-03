import Foundation
import Combine

public struct TelegramCacheRetention: Codable, Equatable, Sendable {
    public var version = 1
    /// Zero means unlimited. Values follow the desktop reference's choices.
    public var days: Int
    public var limitGB: Int
    public init(days: Int = 0, limitGB: Int = 0) { self.days = days; self.limitGB = limitGB }
    var isValid: Bool { version == 1 && [0,1,7,31].contains(days) && [0,5,16,32].contains(limitGB) }
    var enabled: Bool { days > 0 || limitGB > 0 }
    public func encoded() throws -> String {
        guard isValid else { throw TelegramAppearanceError.invalid }
        return String(decoding:try JSONEncoder().encode(self),as:UTF8.self)
    }
    public static func decode(_ input: String) throws -> Self {
        guard input.utf8.count <= 1024 else { throw TelegramAppearanceError.invalid }
        if input.isEmpty { return .init() }
        let value = try JSONDecoder().decode(Self.self,from:Data(input.utf8))
        guard value.isValid else { throw TelegramAppearanceError.invalid }; return value
    }
    func selection(from snapshot: TelegramCacheSnapshot, now: Int64, protectedResources: Set<String> = []) -> [TelegramCacheItem] {
        guard isValid, enabled, snapshot.isValid, now > 0 else { return [] }
        let eligible = snapshot.items.filter { item in
            guard let timestamp = item.modifiedAt, timestamp > 0, timestamp <= now, !item.peerIDs.isEmpty else { return false }
            return Set(item.resources).isDisjoint(with:protectedResources)
        }.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt! < $1.modifiedAt! }
            if $0.namespace != $1.namespace { return $0.namespace < $1.namespace }
            return $0.id < $1.id
        }
        var remaining = snapshot.totalBytes, result: [TelegramCacheItem] = []
        let limit = Int64(limitGB) * 1_000_000_000
        for item in eligible {
            if (days > 0 && item.modifiedAt! < now - Int64(days) * 86_400) || (limitGB > 0 && remaining > limit) {
                result.append(item); remaining -= item.bytes
            }
        }
        return result
    }
}

/// Separate from the manually confirmed cache view: closing a sheet cannot
/// transfer ownership of a background deletion to a different account.
@MainActor public final class TelegramCacheMaintenance: ObservableObject {
    @Published public private(set) var preferences = TelegramCacheRetention()
    @Published public private(set) var accountID: Int64?
    @Published public private(set) var isRunning = false
    @Published public private(set) var status: String?
    @Published public private(set) var error: String?
    @Published public private(set) var lastSnapshot: TelegramCacheSnapshot?
    public var limitExceeded: Bool {
        preferences.limitGB > 0 && (lastSnapshot?.totalBytes ?? 0) > Int64(preferences.limitGB) * 1_000_000_000
    }
    public var permitsClear: @MainActor () -> Bool = { false }
    private let defaults: UserDefaults
    private let now: @MainActor () -> Int64
    private var provider: (any TelegramCacheProvider)?
    private var request: (any TelegramCacheRequest)?
    private var timer: Task<Void,Never>?, deadline: Task<Void,Never>?
    private var generation = UUID(), operation: UUID?
    public init(defaults: UserDefaults = .standard, now: @escaping @MainActor () -> Int64 = { Int64(Date().timeIntervalSince1970) }) {
        self.defaults = defaults; self.now = now
    }
    isolated deinit { timer?.cancel(); deadline?.cancel(); request?.cancel() }
    private func key(_ account: Int64) -> String { "Makosh.Telegram.CacheRetention.v1.\(account)" }
    func bind(provider: (any TelegramCacheProvider)?) {
        cancel(); generation = UUID(); timer?.cancel(); timer = nil
        self.provider = provider; accountID = provider?.accountID
        preferences = .init(); error = nil; status = nil; lastSnapshot = nil
        guard let accountID else { return }
        do { preferences = try .decode(defaults.string(forKey:key(accountID)) ?? "") }
        catch { self.error = "Настройки автоматической очистки повреждены. Выберите их заново." }
        schedule()
    }
    @discardableResult public func update(_ value: TelegramCacheRetention) -> Bool {
        guard let accountID, let encoded = try? value.encoded() else { return false }
        cancel(); defaults.set(encoded,forKey:key(accountID)); preferences = value; error = nil; status = nil
        schedule(); run(); return true
    }
    public func run() {
        guard !isRunning, preferences.enabled, error == nil, let provider, permitsClear() else { return }
        let token = UUID(), context = generation, account = provider.accountID
        operation = token; isRunning = true
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for:.seconds(30)) } catch { return }
            guard let self, self.matches(token,context,account) else { return }
            self.status = "Очистка не подтверждена. Следующая проверка заново прочитает кэш."; self.cancel()
        }
        let started = provider.scan { [weak self] snapshot in
            guard let self, self.matches(token,context,account) else { return }
            guard let snapshot, snapshot.accountID == account, snapshot.isValid else {
                self.status = "Не удалось проверить состав кэша. Файлы сохранены."; self.cancel(); return
            }
            self.lastSnapshot = snapshot
            let selected = self.preferences.selection(from:snapshot,now:self.now())
            guard !selected.isEmpty, self.permitsClear() else { self.cancel(); return }
            let removal = provider.evict(expected:snapshot,items:selected,permitted:{ [weak self] in
                guard let self else { return false }
                return self.matches(token,context,account) && self.permitsClear()
            },receive:{ [weak self] event in
                guard let self, self.matches(token,context,account) else { return }
                switch event {
                case .committing: return
                case let .finished(updated):
                    guard let updated, updated.accountID == account, updated.isValid else {
                        self.status = "Результат очистки не подтверждён. Кэш будет проверен заново."; self.cancel(); return
                    }
                    self.lastSnapshot = updated
                    let protected = self.limitExceeded || !self.preferences.selection(from:updated,now:self.now()).isEmpty
                    self.status = protected ? "Защищённые копии сохранены; срок и лимит будут проверены после их освобождения." : "Автоматическая очистка проверена."
                case .changed: self.status = "Состав кэша изменился. Удаление отложено до следующей проверки."
                case .refused: self.status = "Используемые файлы сохранены. Очистка отложена."
                case .uncertain: self.status = "Результат очистки не подтверждён. Кэш будет проверен заново."
                }
                self.cancel()
            })
            if self.matches(token,context,account) { self.replaceRequest(removal) } else { removal.cancel() }
        }
        // A synchronous scan may already install a removal request or finish.
        if matches(token,context,account), request == nil { request = started } else { started.cancel() }
    }
    private func matches(_ token: UUID,_ context: UUID,_ account: Int64) -> Bool {
        operation == token && generation == context && accountID == account && provider?.accountID == account
    }
    private func replaceRequest(_ value: any TelegramCacheRequest) { let old = request; request = value; old?.cancel() }
    private func cancel() {
        operation = nil; isRunning = false; deadline?.cancel(); deadline = nil
        let old = request; request = nil; old?.cancel()
    }
    private func schedule() {
        timer?.cancel(); timer = nil
        guard provider != nil, preferences.enabled, error == nil else { return }
        let context = generation
        timer = Task { @MainActor [weak self] in
            // First check waits one actor turn for account readiness.
            await Task.yield()
            guard self?.generation == context, !Task.isCancelled else { return }
            self?.run()
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(900)) } catch { return }
                guard self?.generation == context else { return }; self?.run()
            }
        }
    }
}
