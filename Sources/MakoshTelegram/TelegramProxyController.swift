import Foundation
import Combine
import TelegramCore
import SwiftSignalKit

public struct TelegramProxySummary: Identifiable, Equatable {
    public let id: UUID, host: String, port: UInt16, kind: TelegramProxyKind
}
public enum TelegramProxyChange {
    case add(TelegramProxyDraft), replace(UUID, TelegramProxyDraft), remove(UUID), select(UUID), enabled(Bool)
}
public struct TelegramProxyConfirmation: Identifiable {
    public let id = UUID()
    let context: UUID
    let expected: TelegramProxyRecord
    let configuration: TelegramProxyConfiguration
    let retry: Bool
    public let summary: String
}
@MainActor protocol TelegramProxyRequest: AnyObject { func cancel() }
@MainActor protocol TelegramProxyTarget: AnyObject {
    var isAvailable: Bool { get }
    func apply(_ configuration: TelegramProxyConfiguration, receive: @escaping @MainActor (Bool) -> Void) -> any TelegramProxyRequest
    func failClosed()
}
@MainActor public final class TelegramProxyController: ObservableObject {
    public enum Phase: Equatable { case idle, applying, uncertain }
    @Published public private(set) var phase = Phase.idle
    @Published public private(set) var servers: [TelegramProxySummary] = []
    @Published public private(set) var selected: UUID?
    @Published public private(set) var enabled: Bool?
    @Published public private(set) var error: String?
    @Published public private(set) var status: String?
    @Published public private(set) var contextID = UUID()
    @Published public private(set) var isOpening = false
    private let vault: TelegramProxyVault
    private var record: TelegramProxyRecord?
    private let source = ValuePromise<ProxySettings>(ProxySettings(enabled: false, servers: [], activeServer: nil, useForCalls: false), ignoreRepeated: true)
    private var opening = Set<UUID>()
    private var targets: [UUID: any TelegramProxyTarget] = [:]
    private var requests: [UUID: any TelegramProxyRequest] = [:]
    private var pending: [UUID: UUID] = [:]
    private var operation: UUID?
    private var deadline: Task<Void, Never>?
    public convenience init() { self.init(vault: TelegramProxyVault()) }
    init(vault: TelegramProxyVault) { self.vault = vault }
    isolated deinit { deadline?.cancel(); for request in requests.values { request.cancel() } }
    public func open() {
        contextID = UUID()
        guard phase != .applying, opening.isEmpty else { return }
        do {
            let fresh = try vault.read()
            if let record, record != fresh, targets.values.contains(where: \.isAvailable) {
                becomeUncertain(); self.record = fresh; publish(fresh); return
            }
            record = fresh; publish(fresh); error = nil
            if phase != .uncertain { source.set(try fresh.configuration.native()) }
        } catch { becomeUncertain() }
    }
    public func close() { contextID = UUID() }
    public func draft(for id: UUID) -> TelegramProxyDraft? { record?.configuration.servers.first { $0.id == id }?.draft }
    public func prepare(_ change: TelegramProxyChange, contextID: UUID) -> TelegramProxyConfirmation? {
        guard self.contextID == contextID, phase == .idle, opening.isEmpty, let record else { return nil }
        var next = record.configuration
        do {
            switch change {
            case let .add(draft):
                let server = try TelegramProxyServer(draft: draft)
                next.servers.append(server); next.selected = server.id; next.enabled = true
            case let .replace(id, draft):
                guard let index = next.servers.firstIndex(where: { $0.id == id }) else { throw TelegramProxyError.changed }
                next.servers[index] = try TelegramProxyServer(id: id, draft: draft)
            case let .remove(id):
                guard next.servers.contains(where: { $0.id == id }) else { throw TelegramProxyError.changed }
                next.servers.removeAll { $0.id == id }
                if next.selected == id { next.selected = nil; next.enabled = false }
            case let .select(id):
                guard next.servers.contains(where: { $0.id == id }) else { throw TelegramProxyError.changed }
                next.selected = id; next.enabled = true
            case let .enabled(value): next.enabled = value
            }
            guard next.isValid, next != record.configuration else { throw TelegramProxyError.invalid }
            error = nil
            return .init(context: contextID, expected: record, configuration: next, retry: false,
                summary: next.enabled ? "Сохранить настройки и использовать выбранный прокси для соединений Telegram?" : "Сохранить настройки и подключаться к Telegram напрямую?")
        } catch { self.error = "Проверьте адрес, порт, учётные данные и выбранный сервер."; return nil }
    }
    public func prepareRetry(contextID: UUID) -> TelegramProxyConfirmation? {
        guard self.contextID == contextID, phase == .uncertain, opening.isEmpty, let record else { return nil }
        return .init(context: contextID, expected: record, configuration: record.configuration, retry: true,
            summary: "Повторно проверить сохранённые настройки и применить их к соединениям Telegram?")
    }
    public func confirm(_ value: TelegramProxyConfirmation) {
        guard value.context == contextID, opening.isEmpty, record == value.expected,
              phase == (value.retry ? .uncertain : .idle) else { return }
        do {
            let saved: TelegramProxyRecord
            if value.retry {
                saved = try vault.read(); guard saved == value.expected else { throw TelegramProxyError.changed }
            } else { saved = try vault.save(value.configuration, expected: value.expected) }
            record = saved; publish(saved); source.set(try saved.configuration.native())
            contextID = UUID(); error = nil; status = nil; phase = .applying
            let token = UUID(); operation = token
            pending = Dictionary(uniqueKeysWithValues: targets.filter { $0.value.isAvailable }.keys.map { ($0, UUID()) })
            deadline?.cancel()
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.operation == token else { return }; self.becomeUncertain()
            }
            for id in Array(pending.keys) { apply(clientID: id, operation: token) }
            completeIfAcknowledged()
        } catch { becomeUncertain() }
    }
    func settingsForConnection(clientID: UUID) throws -> Signal<ProxySettings, NoError> {
        guard opening.isEmpty, phase != .applying, !targets.values.contains(where: \.isAvailable) || phase != .uncertain else { throw TelegramProxyError.unavailable }
        do {
            let fresh = try vault.read()
            if let record, record != fresh, targets.values.contains(where: \.isAvailable) { throw TelegramProxyError.changed }
            record = fresh; publish(fresh); source.set(try fresh.configuration.native())
            phase = .idle; error = nil; opening.insert(clientID); isOpening = true
            return source.get()
        } catch { becomeUncertain(); throw TelegramProxyError.unavailable }
    }
    func register(_ target: any TelegramProxyTarget, clientID: UUID) {
        guard opening.contains(clientID) || targets[clientID] != nil else { target.failClosed(); return }
        targets[clientID] = target; opening.remove(clientID); isOpening = !opening.isEmpty
        if phase == .uncertain { target.failClosed() }
        else if let operation { pending[clientID] = UUID(); apply(clientID: clientID, operation: operation) }
    }
    func unregister(clientID: UUID) {
        targets.removeValue(forKey: clientID); opening.remove(clientID); isOpening = !opening.isEmpty
        pending.removeValue(forKey: clientID); requests.removeValue(forKey: clientID)?.cancel(); completeIfAcknowledged()
    }
    private func publish(_ record: TelegramProxyRecord) {
        enabled = record.configuration.enabled; selected = record.configuration.selected
        servers = record.configuration.servers.map { .init(id: $0.id, host: $0.host, port: $0.port, kind: $0.kind) }
    }
    private func apply(clientID: UUID, operation: UUID) {
        guard let target = targets[clientID], let attempt = pending[clientID], let record else { return }
        requests.removeValue(forKey: clientID)?.cancel()
        let request = target.apply(record.configuration) { [weak self] success in
            guard let self, self.operation == operation, self.pending[clientID] == attempt else { return }
            guard success else { self.becomeUncertain(); return }
            self.pending.removeValue(forKey: clientID); self.requests.removeValue(forKey: clientID)?.cancel()
            self.completeIfAcknowledged()
        }
        if self.operation == operation, pending[clientID] == attempt { requests[clientID] = request } else { request.cancel() }
    }
    private func completeIfAcknowledged() {
        guard operation != nil, pending.isEmpty else { return }
        operation = nil; deadline?.cancel(); deadline = nil; phase = .idle
        status = "Настройки сохранены и применены. Доступность прокси определяется при соединении."
    }
    private func becomeUncertain() {
        operation = nil; pending = [:]; deadline?.cancel(); deadline = nil
        let old = requests; requests = [:]; for request in old.values { request.cancel() }
        phase = .uncertain; contextID = UUID(); status = nil
        error = "Не удалось подтвердить настройки прокси. Соединения Макоша остановлены. Обновите настройки и подтвердите повторное применение."
        for target in Array(targets.values) { target.failClosed() }
    }
}
