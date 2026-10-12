import TelegramCore

/// Converts the server-selected challenge into only the flows this UI supports.
enum TelegramAuthorizationChallenge: Equatable {
    case phoneCode
    case emailCode
    case unsupported(String)

    init(type: SentAuthorizationCodeType) {
        switch type {
        case .otherSession, .sms, .call, .word, .phrase:
            self = .phoneCode
        case let .email(_, _, _, _, _, setup):
            self = setup ? .unsupported(Self.emailSetupExplanation) : .emailCode
        case .emailSetupRequired:
            self = .unsupported(Self.emailSetupExplanation)
        case .firebase:
            self = .unsupported("Telegram запросил проверку через мобильное приложение. Завершите её в официальном клиенте; этот способ входа пока не поддерживается в Макош.")
        case .fragment:
            self = .unsupported("Telegram предложил вход через Fragment. Этот способ пока не поддерживается в Макош. Продолжите вход в официальном клиенте.")
        case .flashCall, .missedCall:
            self = .unsupported("Telegram запросил проверку по номеру входящего звонка. Этот способ пока не поддерживается в Макош. Продолжите вход в официальном клиенте.")
        }
    }

    var phase: TelegramPhase {
        switch self {
        case .phoneCode, .emailCode: .code
        case .unsupported(let message): .unsupported(message)
        }
    }

    var explanation: String {
        switch self {
        case .phoneCode: "Введите код, слово или фразу входа, полученные от Telegram."
        case .emailCode: "Введите код входа, отправленный Telegram на вашу электронную почту."
        case .unsupported(let message): message
        }
    }

    func authorizationCode(_ value: String) -> AuthorizationCode? {
        switch self {
        case .phoneCode: .phoneCode(value)
        case .emailCode: .emailVerification(.emailCode(value))
        case .unsupported: nil
        }
    }

    private static let emailSetupExplanation = "Telegram требует настройки электронной почты. Завершите настройку в официальном клиенте; этот шаг пока не поддерживается в Макош."
}
