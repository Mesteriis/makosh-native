#if DEBUG
import Foundation

/// Explicit in-memory fixture. These strings are not credentials for any service.
@MainActor final class TelegramSyntheticTwoStepProvider: TelegramTwoStepProvider {
    let accountID: Int64 = -1
    private var password: String? = "Synthetic-Initial-2FA"
    private var email: String? = "synthetic@example.invalid"
    private var hint = "Синтетическая подсказка"
    private var pendingEmail: String?, pendingPassword: String?
    private var secureValues = true
    private var resetAt: Int32?
    private let resetWaitSeconds: Int32
    init(resetWaitSeconds: Int32 = 7 * 86400) { self.resetWaitSeconds = resetWaitSeconds }
    private var passwordGeneration = 1
    private var state: TelegramTwoStepSnapshot {
        .init(accountID: accountID,enabled: password != nil,hint: hint,hasRecoveryEmail: email != nil,pendingEmail: pendingEmail.map { _ in "s***@example.invalid" },hasSecureValues: secureValues,resetAt: resetAt,basisTag: password == nil ? "synthetic-no-password" : "synthetic-password-\(passwordGeneration)")
    }
    func load(receive: @escaping @MainActor (Result<TelegramTwoStepSnapshot, TelegramTwoStepError>) -> Void) -> any TelegramPrivacyRequest {
        receive(.success(state)); return SyntheticTwoStepRequest()
    }
    func perform(_ proposal: TelegramTwoStepProposal, input: TelegramTwoStepInput, receive: @escaping @MainActor (Result<TelegramTwoStepOutcome, TelegramTwoStepError>) -> Void) -> any TelegramPrivacyRequest {
        guard proposal.expected == state, input.isValid(for: proposal.kind) else { receive(.failure(.changed)); return SyntheticTwoStepRequest() }
        if [.changePassword,.changeEmail,.disable].contains(proposal.kind),
           !(input.currentPassword.map { current in password.map { telegramTwoStepPasswordBytesEqual(current, $0) } ?? false } ?? false) {
            receive(.failure(.invalidPassword)); return SyntheticTwoStepRequest()
        }
        let result: Result<TelegramTwoStepOutcome,TelegramTwoStepError>
        switch proposal.kind {
        case .unlock: result = password.map { telegramTwoStepPasswordBytesEqual(input.password, $0) } == true ? .success(.unlocked(email ?? "")) : .failure(.invalidPassword)
        case .setPassword:
            hint = input.hint
            if input.email.isEmpty { password = input.password; passwordGeneration += 1; result = .success(.done) }
            else { pendingPassword = input.password; pendingEmail = input.email; result = .success(.pendingEmail("s***@example.invalid",6)) }
        case .changePassword:
            password = input.password; hint = input.hint; passwordGeneration += 1; result = .success(.done)
        case .changeEmail:
            pendingEmail = input.email; result = .success(.pendingEmail("s***@example.invalid",6))
        case .confirmEmail:
            if input.code != "123456" { result = .failure(.invalidCode) }
            else {
                email = pendingEmail; pendingEmail = nil
                if let value = pendingPassword { password = value; pendingPassword = nil; passwordGeneration += 1 }
                result = .success(.done)
            }
        case .resendEmail: result = .success(.done)
        case .cancelEmail: pendingEmail = nil; pendingPassword = nil; result = .success(.done)
        case .requestRecovery: result = .success(.recoverySent("s***@example.invalid"))
        case .recover:
            if input.code != "123456" { result = .failure(.invalidCode) }
            else { removePassword(); result = .success(.done) }
        case .disable: removePassword(); result = .success(.done)
        case .requestReset:
            if let resetAt, TimeInterval(resetAt) <= Date().timeIntervalSince1970 { removePassword(); result = .success(.done) }
            else if let date = Int32(exactly: Int64(Date().timeIntervalSince1970) + Int64(resetWaitSeconds)) { resetAt = date; result = .success(.resetWaiting(date)) }
            else { result = .failure(.unavailable) }
        case .declineReset: resetAt = nil; result = .success(.done)
        }
        receive(result); return SyntheticTwoStepRequest()
    }
    private func removePassword() {
        password = nil; email = nil; pendingEmail = nil; pendingPassword = nil; hint = ""; secureValues = false; resetAt = nil; passwordGeneration += 1
    }
}
@MainActor private final class SyntheticTwoStepRequest: TelegramPrivacyRequest { func cancel() {} }
#endif
