import Foundation
import MakoshCore

/// The groups of the card's «OSINT» section.
public enum OSINTCardGroup: String, CaseIterable, Sendable {
    case contacts, social, breaches, phone, domains, avatar, organizations

    public var title: String {
        switch self {
        case .contacts: "Адреса и телефоны"
        case .social: "Соцсети"
        case .breaches: "Утечки"
        case .phone: "Телефон"
        case .domains: "Домены"
        case .avatar: "Аватар"
        case .organizations: "Организации"
        }
    }
}

/// One OSINT finding as the card shows it.
public struct OSINTCardItem: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var group: OSINTCardGroup
    public var title: String
    public var value: String
    public var field: String
    public var status: ObservationStatus
    public var fetchedAt: Date
    /// The same pair was once removed by the user: shown, but marked.
    public var formerlyRemoved: Bool
}

public enum OSINTCardGrouping {
    /// Proposed and confirmed OSINT observations of the person, grouped; rejected and foreign ones are left out.
    public static func items(for person: Person) -> [OSINTCardItem] {
        person.observations.compactMap { observation in
            guard observation.source.identity.service == OSINTGraphMapping.service,
                observation.status == .proposed || observation.status == .confirmed, let group = group(for: observation.field)
            else { return nil }
            return OSINTCardItem(
                id: observation.id, group: group, title: title(for: observation.field), value: observation.value, field: observation.field,
                status: observation.status, fetchedAt: observation.source.fetchedAt,
                formerlyRemoved: person.former.contains { $0.field == observation.field && $0.value == observation.value })
        }
    }

    public static func group(for field: String) -> OSINTCardGroup? {
        switch field {
        case "emails", "phones", "usernames": .contacts
        case "breach": .breaches
        case "phone.info": .phone
        case "domain", "domain.ip", "domain.whois": .domains
        case "avatar": .avatar
        case "organization.suggested", "organization.asn": .organizations
        case _ where field.hasPrefix("social."): .social
        case _ where field.hasPrefix("leak."): .breaches
        default: nil
        }
    }

    public static func title(for field: String) -> String {
        if field.hasPrefix("social.") {
            let platform = String(field.dropFirst("social.".count))
            return platformTitles[platform] ?? platform.prefix(1).uppercased() + platform.dropFirst()
        }
        switch field {
        case "emails": return "адрес"
        case "phones": return "телефон"
        case "usernames": return "username"
        case "breach": return "утечка"
        case "phone.info": return "оператор"
        case "domain": return "домен"
        case "domain.ip": return "IP-адрес"
        case "domain.whois": return "WHOIS"
        case "avatar": return "аватар"
        case "organization.suggested": return "организация"
        case "organization.asn": return "автономная система"
        case "leak.device": return "устройство в утечке"
        case "leak.name": return "имя в утечке"
        case "leak.birthdate": return "дата рождения в утечке"
        case "leak.ip": return "IP в утечке"
        case "leak.social": return "профиль в утечке"
        default: return field
        }
    }

    private static let platformTitles = [
        "github": "GitHub", "twitter": "Twitter", "x": "X", "instagram": "Instagram", "facebook": "Facebook", "linkedin": "LinkedIn",
        "telegram": "Telegram", "vk": "ВКонтакте", "youtube": "YouTube", "reddit": "Reddit", "tiktok": "TikTok", "gitlab": "GitLab",
    ]
}
