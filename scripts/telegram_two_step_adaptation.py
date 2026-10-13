# SPDX-License-Identifier: GPL-3.0-or-later
"""Bound reviewed native 2FA ACK and secure-value/algorithm failure paths."""
import hashlib
ACCOUNT_AUTH = "submodules/TelegramCore/Sources/Account/Account.swift"
TWO_STEP = "submodules/TelegramCore/Sources/TelegramEngine/Auth/TwoStepVerification.swift"

def adapt_two_step_source(source):
    if hashlib.sha256(source.encode()).hexdigest() != TWO_STEP_INPUT:
        raise RuntimeError("Unexpected reviewed two-step source fingerprint")
    replacements = [
        ('''                |> mapError { _ -> UpdateTwoStepVerificationPasswordError in
                    return .generic
                }
                |> map { _ -> UpdateTwoStepVerificationPasswordResult in
                    return .none
                }''', '''                |> mapToSignal { value -> Signal<UpdateTwoStepVerificationPasswordResult, MTRpcError> in
                    return makoshTwoStepPasswordAcknowledgement(value, result: .none)
                }
                |> mapError { _ -> UpdateTwoStepVerificationPasswordError in
                    return .generic
                }'''),
        ('''                |> map { _ -> UpdateTwoStepVerificationPasswordResult in
                    return .password(password: password, pendingEmail: nil)
                }''', '''                |> mapToSignal { value -> Signal<UpdateTwoStepVerificationPasswordResult, MTRpcError> in
                    return makoshTwoStepPasswordAcknowledgement(value, result: .password(password: password, pendingEmail: nil))
                }'''),
        ('''        |> map { _ -> UpdateTwoStepVerificationPasswordResult in
            return .password(password: currentPassword, pendingEmail: nil)
        }''', '''        |> mapToSignal { value -> Signal<UpdateTwoStepVerificationPasswordResult, MTRpcError> in
            return makoshTwoStepPasswordAcknowledgement(value, result: .password(password: currentPassword, pendingEmail: nil))
        }'''),
        ('''                        |> map { result -> UpdateTwoStepVerificationPasswordResult in
                            return .password(password: password, pendingEmail: result.unconfirmedEmailPattern.flatMap({ TwoStepVerificationPendingEmail(pattern: $0, codeLength: codeLength) }))
                        }''', '''                        |> mapToSignal { result -> Signal<UpdateTwoStepVerificationPasswordResult, MTRpcError> in
                            guard let pattern = result.unconfirmedEmailPattern, !pattern.isEmpty else {
                                return .fail(MTRpcError(errorCode: 500, errorDescription: "MAKOSH_TWO_STEP_ACK_UNKNOWN"))
                            }
                            return .single(.password(password: password, pendingEmail: TwoStepVerificationPendingEmail(pattern: pattern, codeLength: codeLength)))
                        }'''),
        ('''                |> map { result -> UpdateTwoStepVerificationPasswordResult in
                    var codeLength: Int32?''', '''                |> mapToSignal { result -> Signal<UpdateTwoStepVerificationPasswordResult, MTRpcError> in
                    var codeLength: Int32?'''),
        ('''                    return .password(password: currentPassword, pendingEmail: result.unconfirmedEmailPattern.flatMap({ TwoStepVerificationPendingEmail(pattern: $0, codeLength: codeLength) }))''', '''                    guard let pattern = result.unconfirmedEmailPattern, !pattern.isEmpty else {
                        return .fail(MTRpcError(errorCode: 500, errorDescription: "MAKOSH_TWO_STEP_ACK_UNKNOWN"))
                    }
                    return .single(.password(password: currentPassword, pendingEmail: TwoStepVerificationPendingEmail(pattern: pattern, codeLength: codeLength)))'''),
        ('''hint: "", email: "", newSecureSettings: nil)), automaticFloodWait: true)''', '''hint: "", email: "", newSecureSettings: nil)), automaticFloodWait: false)'''),
    ]
    for old, new in replacements:
        if source.count(old) != 1:
            raise RuntimeError("Unexpected reviewed two-step adaptation context")
        source = source.replace(old, new)
    old = """            |> map { settings in
                return settings.secureSecret
            }"""
    new = """            |> mapToSignal { settings -> Signal<TwoStepVerificationSecureSecret?, UpdateTwoStepVerificationPasswordError> in
                guard makoshTwoStepSecureValuesConsistent(authData.hasSecretValues, settings.secureSecret != nil) else { return .fail(.generic) }
                return .single(settings.secureSecret)
            }"""
    old2 = """        |> map { authData -> (TwoStepAuthData, TwoStepVerificationSecureSecret?) in
            return (authData, secureSecret)
        }"""
    new2 = """        |> mapToSignal { authData -> Signal<(TwoStepAuthData, TwoStepVerificationSecureSecret?), UpdateTwoStepVerificationPasswordError> in
            guard makoshTwoStepSecureValuesConsistent(authData.hasSecretValues, secureSecret != nil) else { return .fail(.generic) }
            return .single((authData, secureSecret))
        }"""
    for old, new in [(old,new),(old2,new2)]:
        if source.count(old) != 1: raise RuntimeError("Unexpected secure-value guard context")
        source = source.replace(old,new)
    for indent in ("                    ", "            "):
        old = (indent + 'if error.errorDescription == "EMAIL_INVALID" {\n'
               + indent + '    return .invalidEmail\n' + indent + '} else {\n'
               + indent + '    return .generic\n' + indent + '}')
        if source.count(old) != 1: raise RuntimeError("Unexpected password/email error classification context")
        source = source.replace(old, indent + 'return makoshTwoStepPasswordError(error)')
    old = 'if error.errorDescription.hasPrefix("EMAIL_UNCONFIRMED") {'
    if source.count(old) != 2: raise RuntimeError("Unexpected pending-email error contexts")
    source = source.replace(old, 'if makoshTwoStepEmailPending(error) {')
    if hashlib.sha256(source.encode()).hexdigest() != TWO_STEP_OUTPUT:
        raise RuntimeError("Unexpected two-step adapted fingerprint")
    return source

def adapt_two_step_account_source(source):
    start = source.index("func _internal_twoStepAuthData(")
    end = source.index("\n}\n",start)+3
    body = source[start:end]
    if hashlib.sha256(body.encode()).hexdigest() != ACCOUNT_AUTH_INPUT:
        raise RuntimeError("Unexpected reviewed two-step auth-data fingerprint")
    old = "|> map { config -> TwoStepAuthData in"
    new = "|> mapToSignal { config -> Signal<TwoStepAuthData, MTRpcError> in"
    if body.count(old) != 1: raise RuntimeError("Unexpected auth-data map context")
    body = body.replace(old,new)
    old = "                let hasRecovery = (flags & (1 << 0)) != 0"
    new = """                guard makoshTwoStepNextSecureAlgoSupported(newSecureAlgo) else {
                    return .fail(MTRpcError(errorCode: 400, errorDescription: "MAKOSH_TWO_STEP_ALGORITHM_UNSUPPORTED"))
                }
"""+old
    if body.count(old) != 1: raise RuntimeError("Unexpected secure algorithm context")
    body = body.replace(old,new)
    body = body.replace("return TwoStepAuthData(","return .single(TwoStepAuthData(").replace("loginEmailPattern: loginEmailPattern)","loginEmailPattern: loginEmailPattern))")
    if hashlib.sha256(body.encode()).hexdigest() != ACCOUNT_AUTH_OUTPUT:
        raise RuntimeError("Unexpected auth-data adapted fingerprint")
    return source[:start]+body+source[end:]

def acknowledgement_source():
    return '''// Own Makosh MIT adapter; linked TelegramCore remains GPL-3.0-or-later.
import TelegramApi
import SwiftSignalKit
import MtProtoKit

public func makoshTwoStepPasswordError(_ error: MTRpcError) -> UpdateTwoStepVerificationPasswordError {
    error.errorCode == 400 && error.errorDescription == "EMAIL_INVALID" ? .invalidEmail : .generic
}
public func makoshTwoStepEmailPending(_ error: MTRpcError) -> Bool {
    guard error.errorCode == 400 else { return false }
    if error.errorDescription == "EMAIL_UNCONFIRMED" { return true }
    guard error.errorDescription.hasPrefix("EMAIL_UNCONFIRMED_") else { return false }
    let suffix = error.errorDescription.dropFirst("EMAIL_UNCONFIRMED_".count)
    guard !suffix.isEmpty, suffix.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int32(suffix) else { return false }
    return (1...16).contains(length)
}

public func makoshTwoStepSecureValuesConsistent(_ hasValues: Bool, _ hasSecret: Bool) -> Bool { hasValues == hasSecret }
public func makoshTwoStepNextSecureAlgoSupported(_ value: Api.SecurePasswordKdfAlgo) -> Bool {
    switch value {
    case .securePasswordKdfAlgoUnknown, .securePasswordKdfAlgoPBKDF2HMACSHA512iter100000: return true
    case .securePasswordKdfAlgoSHA512: return false
    }
}

public func makoshTwoStepPasswordAcknowledgement(_ value: Api.Bool, result: UpdateTwoStepVerificationPasswordResult) -> Signal<UpdateTwoStepVerificationPasswordResult, MTRpcError> {
    guard case .boolTrue = value else {
        return .fail(MTRpcError(errorCode: 500, errorDescription: "MAKOSH_TWO_STEP_ACK_UNKNOWN"))
    }
    return .single(result)
}
'''

TWO_STEP_INPUT = 'ea519781fb90da19e2735ab9ef22d9bbeeae32f24fb7e774b3f1b597dcb1f2e0'
ACCOUNT_AUTH_INPUT = '73889fa77795f79e10256e630dbcb8494f0c7049f2fb697729d53066dc732126'
TWO_STEP_OUTPUT = '5af1e30870d3f4b78fd631cb15cf798210bed1775497011d45cc473add9ab739'
ACCOUNT_AUTH_OUTPUT = 'c88f692f75f0ddee273d628416ee9a0d6c00703f13eea375e03bc5f9ec6ba504'
