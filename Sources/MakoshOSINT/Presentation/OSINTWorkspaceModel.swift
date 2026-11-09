import Combine
import Foundation
import MakoshCore

/// The OSINT module's state on the main actor: a snapshot, the install log and the host-key question.
/// Every call goes to `OSINTService`; no SSH, HTTP or SQL runs here.
@MainActor public final class OSINTWorkspaceModel: ObservableObject {
    public let service: OSINTService

    @Published public private(set) var snapshot: OSINTSnapshot?
    @Published public private(set) var busy = false
    @Published public var error: String?
    @Published public private(set) var installLog: [String] = []
    @Published public private(set) var installing = false
    /// A host key the server offered that the user has not decided about yet.
    @Published public private(set) var pendingFingerprint: String?
    /// Grows each time a run queued from this model has finished and the snapshot was reloaded.
    @Published public private(set) var runsSettled = 0
    private var trustDecision: CheckedContinuation<Bool, Never>?

    public init(service: OSINTService) { self.service = service }

    // MARK: Loading

    public func load() async {
        busy = true
        defer { busy = false }
        do { snapshot = try await service.snapshot() } catch { self.error = Self.describe(error) }
    }

    private func perform(_ body: () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await body()
            snapshot = try await service.snapshot()
            return true
        } catch {
            self.error = Self.describe(error)
            return false
        }
    }

    // MARK: Connection and installation

    public func saveConnection(host: String, port: Int, login: String, password: String?) async {
        _ = await perform { try await service.saveConnection(host: host, port: port, login: login, password: password) }
    }

    /// Checks the connection; an unknown host key waits in `pendingFingerprint` for `trustPendingKey` or `declinePendingKey`.
    public func testConnection() async -> OSINTConnectionReport? {
        busy = true
        defer { busy = false }
        do {
            let report = try await service.testConnection { [weak self] fingerprint in
                await withCheckedContinuation { continuation in
                    _Concurrency.Task { @MainActor in
                        guard let self else { return continuation.resume(returning: false) }
                        self.pendingFingerprint = fingerprint
                        self.trustDecision = continuation
                    }
                }
            }
            snapshot = try? await service.snapshot()
            return report
        } catch {
            self.error = Self.describe(error)
            snapshot = try? await service.snapshot()
            return nil
        }
    }

    public func trustPendingKey() { decide(true) }
    public func declinePendingKey() { decide(false) }

    private func decide(_ trusted: Bool) {
        pendingFingerprint = nil
        trustDecision?.resume(returning: trusted)
        trustDecision = nil
    }

    public func install() async {
        installing = true
        installLog = []
        defer { installing = false }
        _ = await perform {
            _ = try await service.install { [weak self] install in
                _Concurrency.Task { @MainActor in self?.installLog = Self.logLines(install) }
            }
        }
    }

    static func logLines(_ install: OSINTInstall) -> [String] {
        install.steps.filter { $0.state != .pending }.map { step in
            var line = "\(stepTitle(step.kind)): \(stateTitle(step.state))"
            if let message = step.message { line += " — \(message)" }
            if let failure = step.failure { line += " — \(describe(failure))" }
            return line
        }
    }

    static func stepTitle(_ kind: OSINTInstallStepKind) -> String {
        switch kind {
        case .connect: "Соединение"
        case .docker: "Проверка Docker"
        case .checkout: "Исходники flowsint"
        case .env: "Файл .env"
        case .override: "Настройка compose"
        case .build: "Сборка образов"
        case .up: "Запуск служб"
        case .register: "Служебный пользователь"
        case .investigation: "Расследование «Makosh»"
        case .record: "Запись версии"
        }
    }

    static func stateTitle(_ state: OSINTInstallStepState) -> String {
        switch state {
        case .pending: "ожидает"
        case .running: "выполняется…"
        case .done: "готово"
        case .skipped: "пропущено"
        case .failed: "ошибка"
        }
    }

    // MARK: Enrichment

    public func inputs(personID: UUID) async -> [OSINTInput] { (try? await service.inputs(personID: personID)) ?? [] }

    /// Queues the run and, once the runner is idle again, reloads the snapshot: the card moves from
    /// «Идёт запуск…» to the outcome by itself. `runsSettled` tells views to refresh the dossier too.
    public func enrich(personID: UUID, enrichers: Set<OSINTEnricher>, inputs: [OSINTInput]) async -> Bool {
        let queued = await perform { _ = try await service.enrich(personID: personID, enrichers: enrichers, inputs: inputs) }
        guard queued else { return false }
        _Concurrency.Task { [weak self] in
            guard let service = self?.service else { return }
            await service.settled()
            guard let self else { return }
            await self.load()
            self.runsSettled += 1
        }
        return true
    }

    public func accept(personID: UUID, observationID: UUID) async -> PersonAcceptOutcome? {
        var outcome: PersonAcceptOutcome?
        _ = await perform { outcome = try await service.acceptObservation(personID: personID, observationID: observationID) }
        return outcome
    }

    public func reject(personID: UUID, observationID: UUID) async {
        _ = await perform { try await service.rejectObservation(personID: personID, observationID: observationID) }
    }

    public func settle(attemptID: UUID) async { _ = await perform { try await service.settle(attemptID: attemptID) } }
    public func dismiss(attemptID: UUID) async { _ = await perform { try await service.dismiss(attemptID: attemptID) } }
    public func deleteOSINTData(personID: UUID) async { _ = await perform { try await service.deleteOSINTData(personID: personID) } }

    // MARK: Settings

    public func setEnabled(_ enabled: Bool) async {
        _ = await perform {
            var settings = try await service.settings()
            settings.enabled = enabled
            try await service.saveSettings(settings)
            if !enabled { await service.cancelQueuedAutomaticRuns() }
        }
    }

    public func setEnricherSets(manual: Set<OSINTEnricher>, automatic: Set<OSINTEnricher>) async {
        _ = await perform {
            var settings = try await service.settings()
            settings.manualEnrichers = manual
            settings.automaticEnrichers = automatic
            try await service.saveSettings(settings)
        }
    }

    public func setKey(name: String, value: String) async { _ = await perform { try await service.setKey(name: name, value: value) } }
    public func removeKey(name: String) async { _ = await perform { try await service.removeKey(name: name) } }
    public func refreshKeys() async { _ = await perform { _ = try await service.refreshKeys() } }
    public func setServicePassword(_ password: String) async -> Bool { await perform { try await service.setServicePassword(password) } }
    public func registerNewServiceUser() async -> Bool { await perform { try await service.registerNewServiceUser() } }
    public func graphURL(personID: UUID) async -> URL? { try? await service.graphURL(personID: personID) }
    public func webRootURL() async -> URL? { try? await service.webRootURL() }
    public func servicePassword() async -> String? { try? await service.servicePassword() }

    // MARK: Texts

    public static func describe(_ error: Error) -> String {
        guard let failure = error as? OSINTFailure else { return "Не удалось выполнить действие OSINT-модуля." }
        return describe(failure)
    }

    public static func describe(_ failure: OSINTFailure) -> String {
        switch failure {
        case .disabled: "OSINT-модуль выключен. Включите его в Настройках → Персоны."
        case .notInstalled: "Модуль не установлен на сервере. Нажмите «Развернуть модуль»."
        case .sshUnreachable: "Сервер недоступен по SSH."
        case .sshAuthFailed: "Сервер не принял логин или пароль SSH."
        case .hostKeyMismatch: "Отпечаток ключа сервера не подтверждён или изменился. Проверьте соединение и подтвердите отпечаток."
        case .dockerMissing: "На сервере нет Docker или Docker Compose."
        case .gitMissing: "На сервере нет git."
        case .installFailed(let stage): "Установка остановилась на шаге «\(stage)»."
        case .healthTimeout: "Службы flowsint не ответили вовремя."
        case .serviceAuthFailed: "Сервер не принял пароль служебного пользователя. Введите его заново или зарегистрируйте нового."
        case .apiRejected(let code, let stage): "Сервер отклонил запрос (\(code), \(stage))."
        case .unknownOutcome(let stage): "Нет ответа сервера на шаге «\(stage)»: исход неизвестен, проверьте позже."
        case .invalidResponse(let stage): "Сервер ответил непонятно на шаге «\(stage)»."
        case .tooLarge: "Ответ сервера слишком велик."
        case .storage: "Ошибка хранилища OSINT-модуля."
        case .invalidInput(let what): "Некорректные данные: \(what)."
        }
    }
}
