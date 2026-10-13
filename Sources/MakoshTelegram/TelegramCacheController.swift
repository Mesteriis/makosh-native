import Foundation
import Combine

public enum TelegramCacheKind: String, CaseIterable, Identifiable, Sendable {
    case photos, videos, audio, files
    public var id: String { rawValue }
}
nonisolated func telegramCacheResourceIDIsValid(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.count <= 256 && id.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
    }
}
struct TelegramCacheItem: Equatable, Sendable {
    let namespace: Int32, id: Int64, bytes: Int64
    let kind: TelegramCacheKind
    let resources: [String]
}
public struct TelegramCacheSnapshot: Equatable, Sendable {
    public let accountID: Int64
    let items: [TelegramCacheItem]
    public var totalBytes: Int64 { isValid ? items.reduce(0) { $0 + $1.bytes } : 0 }
    public func bytes(for kind: TelegramCacheKind) -> Int64 { isValid ? items.filter { $0.kind == kind }.reduce(0) { $0 + $1.bytes } : 0 }
    var isValid: Bool {
        guard accountID != 0, items.count <= 10_000 else { return false }
        var identities = Set<String>(), resources = Set<String>(), sum: Int64 = 0
        for item in items {
            guard item.namespace >= 0, item.bytes > 0, !item.resources.isEmpty, item.resources.count <= 10_000,
                  identities.insert("\(item.namespace):\(item.id)").inserted else { return false }
            for id in item.resources {
                guard telegramCacheResourceIDIsValid(id), resources.insert(id).inserted, resources.count <= 10_000 else { return false }
            }
            let next = sum.addingReportingOverflow(item.bytes)
            guard !next.overflow else { return false }; sum = next.partialValue
        }
        return true
    }
}
public struct TelegramCacheConfirmation: Identifiable, Equatable, Sendable {
    public let id: UUID
    let contextID: UUID
    let snapshot: TelegramCacheSnapshot
    public let categories: Set<TelegramCacheKind>
    public var byteCount: Int64 { categories.reduce(0) { $0 + snapshot.bytes(for: $1) } }
}
@MainActor protocol TelegramCacheRequest: AnyObject { func cancel() }
enum TelegramCacheEvent { case committing, changed(TelegramCacheSnapshot?), finished(TelegramCacheSnapshot?), refused, uncertain }
@MainActor protocol TelegramCacheProvider: AnyObject {
    var accountID: Int64 { get }
    func scan(receive: @escaping @MainActor (TelegramCacheSnapshot?) -> Void) -> any TelegramCacheRequest
    func clear(expected: TelegramCacheSnapshot, categories: Set<TelegramCacheKind>, permitted: @escaping @MainActor () -> Bool,
        receive: @escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest
}
@MainActor public final class TelegramCacheController: ObservableObject {
    public enum Phase: Equatable { case idle, scanning, validating, clearing, uncertain }
    @Published public private(set) var phase = Phase.idle
    @Published public private(set) var snapshot: TelegramCacheSnapshot?
    @Published public private(set) var error: String?
    @Published public private(set) var contextID = UUID()
    @Published public private(set) var status: String?
    public var permitsClear: @MainActor () -> Bool = { false }
    private var provider: (any TelegramCacheProvider)?
    private var request: (any TelegramCacheRequest)?
    private var operation: UUID?
    private var deadline: Task<Void, Never>?
    private var uncertainAccounts = Set<Int64>()
    public init() {}
    isolated deinit { deadline?.cancel(); request?.cancel() }
    func bind(_ provider: (any TelegramCacheProvider)?) {
        close(); self.provider = provider
        phase = provider.map { uncertainAccounts.contains($0.accountID) ? .uncertain : .idle } ?? .idle
    }
    public func open() { close(); refresh() }
    public func close() {
        if phase == .clearing, let account = provider?.accountID { uncertainAccounts.insert(account) }
        operation = nil; contextID = UUID(); deadline?.cancel(); deadline = nil
        let old = request; request = nil; old?.cancel()
        snapshot = nil; error = nil; status = nil
        phase = provider.map { uncertainAccounts.contains($0.accountID) ? .uncertain : .idle } ?? .idle
    }
    public func refresh() {
        guard phase != .validating, phase != .clearing, let provider else { return }
        operation = nil; let old = request; request = nil; old?.cancel(); deadline?.cancel()
        contextID = UUID(); let context = contextID, token = UUID(), account = provider.accountID
        operation = token; phase = .scanning; snapshot = nil; error = nil; status = nil
        armDeadline(token: token, context: context, account: account)
        let started = provider.scan { [weak self] value in
            guard let self, self.matches(token, context: context, account: account) else { return }
            if let value, value.accountID == account, value.isValid {
                self.snapshot = value; self.uncertainAccounts.remove(account); self.finish(.idle)
            } else { self.error = "Не удалось получить полный допустимый состав кэша. Повторите проверку."; self.finish(.idle) }
        }
        if matches(token, context: context, account: account) { request = started } else { started.cancel() }
    }
    public func prepareClear(categories: Set<TelegramCacheKind>, contextID: UUID) -> TelegramCacheConfirmation? {
        guard phase == .idle, self.contextID == contextID, let snapshot, snapshot.isValid,
              provider?.accountID == snapshot.accountID, !categories.isEmpty, permitsClear(),
              categories.contains(where: { snapshot.bytes(for: $0) > 0 }) else { return nil }
        return .init(id: UUID(), contextID: contextID, snapshot: snapshot, categories: categories)
    }
    @discardableResult public func confirmClear(_ confirmation: TelegramCacheConfirmation) -> Bool {
        guard confirmation.contextID == contextID, confirmation.snapshot == snapshot,
              let provider, prepareClear(categories: confirmation.categories, contextID: confirmation.contextID) != nil else { return false }
        let token = UUID(), context = contextID, account = provider.accountID
        operation = token; phase = .validating; error = nil; status = nil
        armDeadline(token: token, context: context, account: account)
        let started = provider.clear(expected: confirmation.snapshot, categories: confirmation.categories, permitted: { [weak self] in
            guard let self else { return false }
            return self.matches(token, context: context, account: account) && self.permitsClear()
        }, receive: { [weak self] event in
            guard let self, self.matches(token, context: context, account: account) else { return }
            switch event {
            case .committing: self.phase = .clearing
            case let .changed(value):
                self.snapshot = value.flatMap { $0.accountID == account && $0.isValid ? $0 : nil }
                self.error = "Состав кэша изменился. Проверьте обновлённый размер и подтвердите очистку заново."
                self.finish(.idle); self.contextID = UUID()
            case let .finished(value):
                guard let value, value.accountID == account, value.isValid else { self.markUncertain(account); return }
                self.snapshot = value; self.uncertainAccounts.remove(account)
                self.status = "Кэш проверен после очистки. Используемые копии остаются до освобождения."
                self.finish(.idle); self.contextID = UUID()
            case .refused:
                self.error = "Очистка сейчас недоступна. Завершите отправку и сохранение файлов в S3."
                self.finish(.idle); self.contextID = UUID()
            case .uncertain: self.markUncertain(account)
            }
        })
        if matches(token, context: context, account: account) { request = started } else { started.cancel() }
        return true
    }
    private func matches(_ token: UUID, context: UUID, account: Int64) -> Bool {
        operation == token && contextID == context && provider?.accountID == account
    }
    private func finish(_ phase: Phase) {
        operation = nil; deadline?.cancel(); deadline = nil; self.phase = phase
        let old = request; request = nil; old?.cancel()
    }
    private func markUncertain(_ account: Int64) {
        uncertainAccounts.insert(account); error = "Результат очистки ещё не подтверждён. Обновите состав кэша перед следующим действием."
        finish(.uncertain)
    }
    private func armDeadline(token: UUID, context: UUID, account: Int64) {
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.matches(token, context: context, account: account) else { return }
            if self.phase == .clearing { self.markUncertain(account) }
            else { self.error = "Telegram не завершил проверку кэша за30секунд. Повторите загрузку."; self.finish(.idle) }
        }
    }
}
