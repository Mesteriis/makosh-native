import Foundation
import Combine

func telegramTwoStepPasswordBytesEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

public struct TelegramTwoStepSnapshot: Equatable, Sendable {
    public let accountID: Int64
    public let enabled: Bool
    public let hint: String
    public let hasRecoveryEmail: Bool
    public let pendingEmail: String?
    public let hasSecureValues: Bool
    public let resetAt: Int32?
    let basisTag: String
    var isValid: Bool {
        accountID != 0 && hint.utf8.count <= 4096 && !basisTag.isEmpty && basisTag.count <= 128
            && (enabled || (!hasRecoveryEmail && !hasSecureValues && resetAt == nil))
            && (pendingEmail.map { !$0.isEmpty && $0.utf8.count <= 512 } ?? true)
            && (resetAt.map { $0 >= 0 } ?? true)
    }
}
public enum TelegramTwoStepKind: String, Sendable {
    case unlock, setPassword, changePassword, changeEmail, disable, confirmEmail, resendEmail, cancelEmail, requestRecovery, recover, requestReset, declineReset
}
public struct TelegramTwoStepInput: CustomStringConvertible, CustomDebugStringConvertible {
    public let password: String, confirmation: String, hint: String, email: String, code: String
    let currentPassword: String?
    public init(password: String = "", confirmation: String = "", hint: String = "", email: String = "", code: String = "") {
        self.password = password; self.confirmation = confirmation; self.hint = hint; self.email = email; self.code = code; currentPassword = nil
    }
    init(_ value: TelegramTwoStepInput, currentPassword: String?) {
        password = value.password; confirmation = value.confirmation; hint = value.hint; email = value.email; code = value.code; self.currentPassword = currentPassword
    }
    public var description: String { "TelegramTwoStepInput(<redacted>)" }
    public var debugDescription: String { description }
    func isValid(for kind: TelegramTwoStepKind) -> Bool {
        guard password.utf8.count <= 1024, confirmation.utf8.count <= 1024, hint.utf8.count <= 256,
              email.utf8.count <= 254, code.utf8.count <= 16, (currentPassword?.utf8.count ?? 0) <= 1024 else { return false }
        func validEmail(_ value: String) -> Bool {
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && !value.contains(where: { $0.isWhitespace || $0.isNewline })
        }
        switch kind {
        case .unlock: return !password.isEmpty
        case .setPassword, .changePassword:
            return !password.isEmpty && telegramTwoStepPasswordBytesEqual(password, confirmation) && hint.caseInsensitiveCompare(password) != .orderedSame
                && (kind == .changePassword ? email.isEmpty : email.isEmpty || validEmail(email))
        case .changeEmail: return validEmail(email)
        case .confirmEmail, .recover: return !code.isEmpty && code.utf8.allSatisfy { (48...57).contains($0) }
        default: return true
        }
    }
}
public struct TelegramTwoStepProposal: Equatable {
    public let kind: TelegramTwoStepKind
    public let contextID: UUID
    public let expected: TelegramTwoStepSnapshot
}
enum TelegramTwoStepError: Error, Equatable { case unavailable, changed, invalidPassword, invalidEmail, invalidCode, expired, flood, resetDeclined, uncertain }
enum TelegramTwoStepOutcome: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    case done, pendingEmail(String, Int32?), unlocked(String), recoverySent(String), resetWaiting(Int32)
    var description: String { "TelegramTwoStepOutcome(<redacted>)" }
    var debugDescription: String { description }
}
@MainActor protocol TelegramTwoStepProvider: AnyObject {
    var accountID: Int64 { get }
    func load(receive: @escaping @MainActor (Result<TelegramTwoStepSnapshot, TelegramTwoStepError>) -> Void) -> any TelegramPrivacyRequest
    func perform(_ proposal: TelegramTwoStepProposal, input: TelegramTwoStepInput, receive: @escaping @MainActor (Result<TelegramTwoStepOutcome, TelegramTwoStepError>) -> Void) -> any TelegramPrivacyRequest
}
@MainActor public final class TelegramTwoStepController: ObservableObject {
    @Published public private(set) var snapshot: TelegramTwoStepSnapshot?
    @Published public private(set) var status: TelegramSearchStatus = .idle
    @Published public private(set) var contextID = UUID()
    @Published public private(set) var isWorking = false
    @Published public private(set) var isUnlocked = false
    @Published public private(set) var isUncertain = false
    @Published public private(set) var recoveryEmail: String?
    @Published public private(set) var recoveryPattern: String?
    @Published public private(set) var feedback = ""
    private var provider: (any TelegramTwoStepProvider)?
    private var read: (any TelegramPrivacyRequest)?, action: (any TelegramPrivacyRequest)?
    private var readID: UUID?, actionID: UUID?, actionKind: TelegramTwoStepKind?
    private var readDeadline: Task<Void, Never>?, actionDeadline: Task<Void, Never>?
    private var passwordProof: String?
    private var proofDeadline: Task<Void, Never>?
    private var proofID: UUID?
    private var proofExpires: ContinuousClock.Instant?
    private var uncertainAccounts: Set<Int64> = []
    public init() {}
    isolated deinit { read?.cancel(); action?.cancel(); readDeadline?.cancel(); actionDeadline?.cancel(); proofDeadline?.cancel() }
    func bind(_ provider: (any TelegramTwoStepProvider)?) { close(); self.provider = provider }
    private func clearProof() {
        proofID = nil; proofExpires = nil; proofDeadline?.cancel(); proofDeadline = nil
        passwordProof = nil; isUnlocked = false; recoveryEmail = nil
    }
    public func open() {
        close(); isUncertain = provider.map { uncertainAccounts.contains($0.accountID) } ?? false
        load(reconcile: false)
    }
    public func close() {
        if isWorking, actionKind != .unlock, let id = provider?.accountID { uncertainAccounts.insert(id) }
        contextID = UUID(); readID = nil; actionID = nil; actionKind = nil
        read?.cancel(); read = nil; action?.cancel(); action = nil
        readDeadline?.cancel(); readDeadline = nil; actionDeadline?.cancel(); actionDeadline = nil
        clearProof(); recoveryPattern = nil; snapshot = nil; status = .idle; feedback = ""; isWorking = false; isUncertain = false
    }
    public func refresh() { guard !isWorking else { return }; recoveryPattern = nil; load(reconcile: true) }
    func expireProof() {
        guard isUnlocked, !isWorking else { return }
        clearProof(); contextID = UUID(); feedback = "Введите текущий пароль заново. Время подтверждения истекло."
    }
    private func load(reconcile: Bool) {
        clearProof(); contextID = UUID(); readID = nil; read?.cancel(); read = nil; readDeadline?.cancel(); readDeadline = nil
        snapshot = nil
        guard let provider else { status = .failed; return }
        let token = UUID(), context = contextID, account = provider.accountID
        readID = token; status = .loading
        readDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.readID == token else { return }
            self.readID = nil; self.read?.cancel(); self.read = nil; self.status = .timedOut
        }
        let request = provider.load { [weak self] value in
            guard let self, self.contextID == context, self.readID == token else { return }
            self.readID = nil; self.read?.cancel(); self.read = nil; self.readDeadline?.cancel(); self.readDeadline = nil
            switch value {
            case .failure: self.status = .failed
            case let .success(state):
                guard state.accountID == account, state.isValid else { self.status = .failed; return }
                self.snapshot = state; self.status = .ready
                if reconcile { self.uncertainAccounts.remove(account); self.isUncertain = false; self.feedback = "Состояние обновлено. Введите пароль заново при необходимости." }
            }
        }
        if readID == token { read = request } else { request.cancel() }
    }
    public func proposal(_ kind: TelegramTwoStepKind) -> TelegramTwoStepProposal? {
        guard status == .ready, !isWorking, !isUncertain, let state = snapshot, state.isValid, state.accountID == provider?.accountID else { return nil }
        let eligible: Bool
        switch kind {
        case .unlock: eligible = state.enabled && !isUnlocked
        case .setPassword: eligible = !state.enabled && state.pendingEmail == nil
        case .changePassword, .changeEmail, .disable:
            eligible = state.enabled && isUnlocked && passwordProof != nil && proofExpires.map { .now < $0 } == true
        case .confirmEmail, .resendEmail, .cancelEmail: eligible = state.pendingEmail != nil
        case .requestRecovery: eligible = state.enabled && state.hasRecoveryEmail
        case .recover: eligible = state.enabled && recoveryPattern != nil
        case .requestReset: eligible = state.enabled && (state.resetAt.map { TimeInterval($0) <= Date().timeIntervalSince1970 } ?? true)
        case .declineReset: eligible = state.resetAt != nil
        }
        guard eligible else { return nil }
        return .init(kind: kind, contextID: contextID, expected: state)
    }
    @discardableResult public func perform(_ proposal: TelegramTwoStepProposal, input: TelegramTwoStepInput = .init()) -> Bool {
        guard proposal == self.proposal(proposal.kind), input.isValid(for: proposal.kind), let provider else { return false }
        let payload = TelegramTwoStepInput(input, currentPassword: passwordProof)
        let token = UUID(), context = contextID, kind = proposal.kind
        actionID = token; actionKind = kind; isWorking = true; feedback = "Ждём ответ Telegram…"
        clearProof()
        actionDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.actionID == token else { return }; self.timeoutAction()
        }
        let request = provider.perform(proposal, input: payload) { [weak self] result in
            guard let self, self.actionID == token, self.contextID == context else { return }
            self.actionID = nil; self.actionKind = nil; self.isWorking = false
            self.action?.cancel(); self.action = nil; self.actionDeadline?.cancel(); self.actionDeadline = nil
            switch result {
            case let .success(outcome):
                guard outcome.isValid(for: kind) else { self.markUncertain(account: provider.accountID); return }
                switch outcome {
                case let .unlocked(email):
                    self.contextID = UUID()
                    self.passwordProof = input.password; self.isUnlocked = true; self.recoveryEmail = email
                    let proofID = UUID(); self.proofID = proofID; self.proofExpires = .now.advanced(by: .seconds(300))
                    self.proofDeadline = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(300)) } catch { return }
                        guard let self, self.proofID == proofID else { return }
                        self.expireProof()
                    }
                    self.feedback = "Пароль подтверждён"
                case let .recoverySent(pattern):
                    self.contextID = UUID(); self.recoveryPattern = pattern; self.feedback = "Код восстановления отправлен"
                case .pendingEmail:
                    self.recoveryPattern = nil; self.feedback = "Подтвердите адрес кодом из письма"; self.load(reconcile: false)
                case .resetWaiting:
                    self.recoveryPattern = nil; self.feedback = "Сервер назначил ожидание сброса"; self.load(reconcile: false)
                case .done:
                    self.recoveryPattern = nil; self.feedback = "Telegram подтвердил операцию"; self.load(reconcile: false)
                }
            case let .failure(error):
                self.clearProof(); self.feedback = error.message
                if error == .changed { self.recoveryPattern = nil; self.load(reconcile: false) }
                else if error == .uncertain, kind != .unlock { self.markUncertain(account: provider.accountID) }
            }
        }
        if actionID == token { action = request } else { request.cancel() }
        return true
    }
    private func markUncertain(account: Int64) {
        clearProof(); uncertainAccounts.insert(account); isUncertain = true; feedback = TelegramTwoStepError.uncertain.message
    }
    func timeoutAction() {
        guard isWorking, let provider, let kind = actionKind else { return }
        actionID = nil; actionKind = nil; isWorking = false; action?.cancel(); action = nil; actionDeadline?.cancel(); actionDeadline = nil
        clearProof()
        if kind == .unlock { feedback = "Время проверки пароля истекло" }
        else { markUncertain(account: provider.accountID) }
    }
}
extension TelegramTwoStepOutcome {
    func isValid(for kind: TelegramTwoStepKind) -> Bool {
        switch self {
        case .done: return kind != .unlock && kind != .requestRecovery
        case let .unlocked(email): return kind == .unlock && email.utf8.count <= 512
        case let .pendingEmail(pattern, length):
            return [.setPassword,.changePassword,.changeEmail].contains(kind) && !pattern.isEmpty && pattern.utf8.count <= 512
                && (length.map { (1...16).contains($0) } ?? true)
        case let .recoverySent(pattern): return kind == .requestRecovery && !pattern.isEmpty && pattern.utf8.count <= 512
        case let .resetWaiting(date): return kind == .requestReset && date > 0
        }
    }
}
extension TelegramTwoStepError {
    var message: String {
        switch self {
        case .unavailable: "Операция недоступна. Обновите настройки."
        case .changed: "Настройки изменились. Проверьте их и подтвердите заново."
        case .invalidPassword: "Неверный пароль"
        case .invalidEmail: "Проверьте адрес электронной почты"
        case .invalidCode: "Неверный код"
        case .expired: "Код истёк. Запросите новый."
        case .flood: "Telegram ограничил частоту запросов. Повторите позже."
        case .resetDeclined: "Запрос сброса был отклонён"
        case .uncertain: "Результат неизвестен. Обновите настройки перед новым действием."
        }
    }
}
