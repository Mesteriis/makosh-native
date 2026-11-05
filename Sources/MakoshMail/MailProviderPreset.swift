import Foundation

/// Known IMAP/SMTP endpoints for the manual account form. Every provider is
/// reached with an app password over verified TLS; OAuth stays out of scope.
public enum MailProviderPreset: String, CaseIterable, Identifiable, Sendable {
    case iCloud, gmail, yandex, mailRu, proton, other

    public struct Servers: Equatable, Sendable {
        public let imapHost: String
        public let imapPort: Int
        public let imapSecurity: MailConnectionSecurity
        public let smtpHost: String
        public let smtpPort: Int
        public let smtpSecurity: MailConnectionSecurity
    }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .iCloud: "iCloud"
        case .gmail: "Gmail"
        case .yandex: "Яндекс"
        case .mailRu: "Mail.ru"
        case .proton: "Proton Mail"
        case .other: "Другой"
        }
    }

    public var hint: String {
        switch self {
        case .iCloud: "Нужен пароль приложения из настроек Apple ID (account.apple.com)."
        case .gmail: "Нужны двухэтапная проверка и пароль приложения Google; IMAP включается в настройках Gmail."
        case .yandex: "Включите доступ по IMAP в настройках Яндекс Почты и создайте пароль приложения."
        case .mailRu: "Создайте пароль для внешнего приложения в настройках безопасности Mail.ru."
        case .proton:
            "Работает через Proton Mail Bridge: имя пользователя и пароль берутся из Bridge, его сертификат должен быть доверенным в Связке ключей."
        case .other: "Укажите серверы и защиту вашего почтового провайдера."
        }
    }

    public var servers: Servers? {
        switch self {
        case .iCloud:
            Servers(
                imapHost: "imap.mail.me.com", imapPort: 993, imapSecurity: .tls, smtpHost: "smtp.mail.me.com", smtpPort: 587,
                smtpSecurity: .startTLS)
        case .gmail:
            Servers(
                imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls, smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .tls
            )
        case .yandex:
            Servers(
                imapHost: "imap.yandex.ru", imapPort: 993, imapSecurity: .tls, smtpHost: "smtp.yandex.ru", smtpPort: 465, smtpSecurity: .tls
            )
        case .mailRu:
            Servers(
                imapHost: "imap.mail.ru", imapPort: 993, imapSecurity: .tls, smtpHost: "smtp.mail.ru", smtpPort: 465, smtpSecurity: .tls)
        case .proton:
            Servers(
                imapHost: "127.0.0.1", imapPort: 1143, imapSecurity: .startTLS, smtpHost: "127.0.0.1", smtpPort: 1025,
                smtpSecurity: .startTLS)
        case .other: nil
        }
    }

    /// The preset whose servers an existing account uses, or `.other`.
    public init(matching account: MailAccount) {
        let servers = Servers(
            imapHost: account.imapHost.lowercased(), imapPort: account.imapPort, imapSecurity: account.imapSecurity,
            smtpHost: account.smtpHost.lowercased(), smtpPort: account.smtpPort, smtpSecurity: account.smtpSecurity)
        self = Self.allCases.first { $0.servers == servers } ?? .other
    }
}
