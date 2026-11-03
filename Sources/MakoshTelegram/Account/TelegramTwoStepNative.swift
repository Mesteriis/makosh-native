import Foundation
import CryptoKit
import TelegramApi
import SwiftSignalKit
import TelegramCore

func telegramTwoStepPasswordOutcome(_ value: UpdateTwoStepVerificationPasswordResult, kind: TelegramTwoStepKind, input: TelegramTwoStepInput) -> TelegramTwoStepOutcome? {
    guard input.isValid(for: kind) else { return nil }
    switch value {
    case .none: return kind == .disable ? .done : nil
    case let .password(password, pending):
        let expected: String?
        switch kind {
        case .setPassword, .changePassword: expected = input.password
        case .changeEmail: expected = input.currentPassword
        default: return nil
        }
        guard let expected, telegramTwoStepPasswordBytesEqual(password, expected) else { return nil }
        let outcome: TelegramTwoStepOutcome = pending.map { .pendingEmail($0.pattern,$0.codeLength) } ?? .done
        return outcome.isValid(for: kind) ? outcome : nil
    }
}
func telegramTwoStepRecoveryRPC(input: TelegramTwoStepInput) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.auth.Authorization>)? {
    guard input.isValid(for: .recover) else { return nil }
    return Api.functions.auth.recoverPassword(flags: 0,code: input.code,newSettings: nil)
}
func telegramTwoStepRecoveryOutcome(_ value: Api.auth.Authorization, selfID: Int64) -> TelegramTwoStepOutcome? {
    guard case let .authorization(_, _, _, _, user) = value,
          case let .user(_, _, id, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) = user,
          id == selfID, id > 0 else { return nil }
    return .done
}
func telegramTwoStepResetOutcome(_ value: Api.account.ResetPasswordResult) -> Result<TelegramTwoStepOutcome,TelegramTwoStepError> {
    switch value {
    case .resetPasswordOk: return .success(.done)
    case let .resetPasswordRequestedWait(date): return date > 0 ? .success(.resetWaiting(date)) : .failure(.uncertain)
    case .resetPasswordFailedWait: return .failure(.flood)
    }
}
func telegramTwoStepRPCError(code: Int, description: String, writing: Bool) -> TelegramTwoStepError {
    let fallback: TelegramTwoStepError = writing ? .uncertain : .unavailable
    if code == 420, description.hasPrefix("FLOOD_WAIT_") {
        let seconds = description.dropFirst("FLOOD_WAIT_".count)
        if !seconds.isEmpty, seconds.utf8.allSatisfy({ (48...57).contains($0) }), Int32(seconds) != nil { return .flood }
    }
    guard code == 400 else { return fallback }
    if description == "PASSWORD_HASH_INVALID" { return .invalidPassword }
    if description == "EMAIL_INVALID" { return .invalidEmail }
    if ["CODE_INVALID","CODE_EMPTY","PASSWORD_RECOVERY_INVALID"].contains(description) { return .invalidCode }
    if description == "EMAIL_HASH_EXPIRED" || description == "PASSWORD_RECOVERY_EXPIRED" { return .expired }
    if description == "RESET_PREVIOUS_DECLINE" { return .resetDeclined }
    if description == "PASSWORD_RECOVERY_NA" { return .changed }
    return fallback
}
func telegramTwoStepSnapshot(_ response: Api.account.Password, accountID: Int64) -> TelegramTwoStepSnapshot? {
    guard case let .password(flags, current, b, srp, hint, pending, _, _, _, reset, _) = response else { return nil }
    let enabled = current != nil
    guard enabled == (flags & (1 << 2) != 0), !enabled || (b != nil && srp != nil) else { return nil }
    let buffer = Buffer()
    if let current {
        guard case .passwordKdfAlgoUnknown = current else {
            current.serialize(buffer, true)
            let bytes = buffer.makeData(); guard bytes.count <= 8192 else { return nil }
            let value = TelegramTwoStepSnapshot(accountID: accountID, enabled: enabled, hint: hint ?? "", hasRecoveryEmail: flags & 1 != 0,
                pendingEmail: pending, hasSecureValues: flags & 2 != 0, resetAt: reset, basisTag: SHA256.hash(data: bytes).map { String(format: "%02x",$0) }.joined())
            return value.isValid ? value : nil
        }
        return nil
    }
    let value = TelegramTwoStepSnapshot(accountID: accountID, enabled: false, hint: hint ?? "", hasRecoveryEmail: flags & 1 != 0,
        pendingEmail: pending, hasSecureValues: flags & 2 != 0, resetAt: reset, basisTag: "no-password")
    return value.isValid ? value : nil
}
func telegramTwoStepBoolRPC(_ kind: TelegramTwoStepKind, input: TelegramTwoStepInput) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.Bool>)? {
    guard input.isValid(for: kind) else { return nil }
    switch kind {
    case .confirmEmail: return Api.functions.account.confirmPasswordEmail(code: input.code)
    case .resendEmail: return Api.functions.account.resendPasswordEmail()
    case .cancelEmail: return Api.functions.account.cancelPasswordEmail()
    case .declineReset: return Api.functions.account.declinePasswordReset()
    default: return nil
    }
}
func telegramTwoStepValue<T>(_ signal: Signal<T,TelegramTwoStepError>, emptyError: TelegramTwoStepError = .uncertain) -> Signal<T,TelegramTwoStepError> {
    Signal { subscriber in
        let received = Atomic(value: false)
        return (signal |> take(1)).start(next: { value in
            _ = received.swap(true); subscriber.putNext(value)
        }, error: { subscriber.putError($0) }, completed: {
            if received.with({ $0 }) { subscriber.putCompletion() } else { subscriber.putError(emptyError) }
        })
    }
}
func telegramTwoStepBoolAcknowledgement(_ signal: Signal<Api.Bool, TelegramTwoStepError>) -> Signal<TelegramTwoStepOutcome, TelegramTwoStepError> {
    telegramTwoStepValue(signal |> mapToSignal { ack in
        guard case .boolTrue = ack else { return .fail(.uncertain) }; return .single(.done)
    })
}
func telegramPerformTwoStep(proposal: TelegramTwoStepProposal, accountID: Int64,
    load: () -> Signal<TelegramTwoStepSnapshot, TelegramTwoStepError>,
    perform: @escaping () -> Signal<TelegramTwoStepOutcome, TelegramTwoStepError>) -> Signal<TelegramTwoStepOutcome, TelegramTwoStepError> {
    guard accountID == proposal.expected.accountID, proposal.expected.isValid else { return .fail(.changed) }
    return telegramTwoStepValue(load() |> take(1) |> mapToSignal { fresh in
        guard fresh.isValid, fresh == proposal.expected, fresh.accountID == accountID else { return .fail(.changed) }
        return perform()
    })
}
