import Foundation
import TelegramCore
import TelegramApi
import SwiftSignalKit

private final class TwoStepBackend {
    let account: Account
    private let engine: TelegramEngine
    init(account: Account) { self.account = account; engine = TelegramEngine(account: account) }
    func load() -> Signal<TelegramTwoStepSnapshot,TelegramTwoStepError> {
        telegramTwoStepValue(account.network.request(Api.functions.account.getPassword(),automaticFloodWait: false)
            |> mapError { _ in TelegramTwoStepError.unavailable }
            |> mapToSignal { [account] response in
                guard let state = telegramTwoStepSnapshot(response,accountID: account.peerId.toInt64()) else { return .fail(.unavailable) }
                return .single(state)
            },emptyError: .unavailable)
    }
    func perform(_ proposal: TelegramTwoStepProposal, input: TelegramTwoStepInput) -> Signal<TelegramTwoStepOutcome,TelegramTwoStepError> {
        guard input.isValid(for: proposal.kind) else { return .fail(.unavailable) }
        return telegramPerformTwoStep(proposal: proposal,accountID: account.peerId.toInt64(),load: { self.load() },perform: {
            self.action(proposal,input: input)
        })
    }
    private func action(_ proposal: TelegramTwoStepProposal, input: TelegramTwoStepInput) -> Signal<TelegramTwoStepOutcome,TelegramTwoStepError> {
        let state = proposal.expected, kind = proposal.kind
        if [.changePassword,.changeEmail,.disable].contains(kind) {
            guard state.enabled, let password = input.currentPassword, !password.isEmpty else { return .fail(.changed) }
        }
        switch kind {
        case .unlock:
            guard state.enabled else { return .fail(.changed) }
            return engine.auth.requestTwoStepVerifiationSettings(password: input.password)
                |> mapError { error in
                    switch error { case .invalidPassword: .invalidPassword; case .limitExceeded: .flood; case .generic: TelegramTwoStepError.unavailable }
                } |> map { .unlocked($0.email) }
        case .setPassword, .changePassword, .disable, .changeEmail:
            if kind == .setPassword { guard !state.enabled, state.pendingEmail == nil else { return .fail(.changed) } }
            let operation: Signal<UpdateTwoStepVerificationPasswordResult,UpdateTwoStepVerificationPasswordError>
            if kind == .changeEmail { operation = engine.auth.updateTwoStepVerificationEmail(currentPassword: input.currentPassword ?? "",updatedEmail: input.email) }
            else {
                let updated: UpdatedTwoStepVerificationPassword = kind == .disable ? .none : .password(password: input.password,hint: input.hint,email: kind == .setPassword && !input.email.isEmpty ? input.email : nil)
                operation = engine.auth.updateTwoStepVerificationPassword(currentPassword: kind == .setPassword ? nil : input.currentPassword,updatedPassword: updated)
            }
            return operation |> mapError { error in
                switch error { case .invalidEmail: TelegramTwoStepError.invalidEmail; case .generic: .uncertain }
            } |> mapToSignal { value in
                guard let outcome = telegramTwoStepPasswordOutcome(value,kind: kind,input: input) else { return .fail(.uncertain) }
                return .single(outcome)
            }
        case .confirmEmail,.resendEmail,.cancelEmail,.declineReset:
            guard kind == .declineReset ? state.resetAt != nil : state.pendingEmail != nil,
                  let rpc = telegramTwoStepBoolRPC(kind,input: input) else { return .fail(.changed) }
            return telegramTwoStepBoolAcknowledgement(account.network.request(rpc,automaticFloodWait: false)
                |> mapError { telegramTwoStepRPCError(code: Int($0.errorCode),description: $0.errorDescription,writing: true) })
        case .requestRecovery:
            guard state.enabled, state.hasRecoveryEmail else { return .fail(.changed) }
            return account.network.request(Api.functions.auth.requestPasswordRecovery(),automaticFloodWait: false)
                |> mapError { telegramTwoStepRPCError(code: Int($0.errorCode),description: $0.errorDescription,writing: true) }
                |> mapToSignal { value in
                    guard case let .passwordRecovery(pattern) = value, !pattern.isEmpty, pattern.utf8.count <= 512 else { return .fail(.uncertain) }
                    return .single(.recoverySent(pattern))
                }
        case .recover:
            guard state.enabled, let rpc = telegramTwoStepRecoveryRPC(input: input) else { return .fail(.changed) }
            return account.network.request(rpc,automaticFloodWait: false)
                |> mapError { telegramTwoStepRPCError(code: Int($0.errorCode),description: $0.errorDescription,writing: true) }
                |> mapToSignal { [account] value in
                    // The already authorized account remains selected; no recovered login/token is installed.
                    guard let outcome = telegramTwoStepRecoveryOutcome(value,selfID: account.peerId.id._internalGetInt64Value()) else { return .fail(.uncertain) }
                    return .single(outcome)
                }
        case .requestReset:
            guard state.enabled else { return .fail(.changed) }
            return account.network.request(Api.functions.account.resetPassword(),automaticFloodWait: false)
                |> mapError { telegramTwoStepRPCError(code: Int($0.errorCode),description: $0.errorDescription,writing: true) }
                |> mapToSignal { value in
                    switch telegramTwoStepResetOutcome(value) { case let .success(outcome): return .single(outcome); case let .failure(error): return .fail(error) }
                }
        }
    }
}
@MainActor final class TelegramEngineTwoStepProvider: TelegramTwoStepProvider {
    let accountID: Int64
    private let backend: TwoStepBackend
    init(account: Account) { accountID = account.peerId.toInt64(); backend = .init(account: account) }
    func load(receive: @escaping @MainActor (Result<TelegramTwoStepSnapshot, TelegramTwoStepError>) -> Void) -> any TelegramPrivacyRequest {
        let request = TwoStepRequest()
        request.disposable.set((backend.load() |> deliverOnMainQueue).start(next: { value in MainActor.assumeIsolated { receive(.success(value)) } },error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
    func perform(_ proposal: TelegramTwoStepProposal, input: TelegramTwoStepInput, receive: @escaping @MainActor (Result<TelegramTwoStepOutcome, TelegramTwoStepError>) -> Void) -> any TelegramPrivacyRequest {
        let request = TwoStepRequest()
        request.disposable.set((backend.perform(proposal,input: input) |> deliverOnMainQueue).start(next: { value in MainActor.assumeIsolated { receive(.success(value)) } },error: { error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
}
@MainActor private final class TwoStepRequest: TelegramPrivacyRequest {
    let disposable = MetaDisposable()
    func cancel() { disposable.dispose() }
    isolated deinit { disposable.dispose() }
}
