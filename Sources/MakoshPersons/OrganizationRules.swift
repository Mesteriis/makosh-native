import Foundation
import MakoshCore

/// An organization the collector should attach a person to, created if it does not exist yet.
public struct OrganizationSuggestion: Equatable, Sendable {
    public var organizationName: String
    public var existingOrganizationID: UUID?
    public var origin: MembershipOrigin
    public var role: String
    public init(organizationName: String, existingOrganizationID: UUID?, origin: MembershipOrigin, role: String) {
        self.organizationName = organizationName
        self.existingOrganizationID = existingOrganizationID
        self.origin = origin
        self.role = role
    }
}

/// Where organizations come from: the «компания» field of sources and e-mail domains
/// that are not public mail providers and are shared by at least two collected addresses.
public enum OrganizationRules {
    public static let builtInStopDomains: Set<String> = [
        "gmail.com", "googlemail.com", "yandex.ru", "yandex.com", "yandex.by", "yandex.kz", "yandex.ua", "ya.ru", "mail.ru", "bk.ru",
        "list.ru", "inbox.ru", "internet.ru", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
        "proton.me", "protonmail.com", "pm.me", "rambler.ru", "lenta.ru", "autorambler.ru", "myrambler.ru", "yahoo.com", "aol.com",
        "gmx.com", "gmx.de", "web.de", "fastmail.com", "tutanota.com", "tuta.io", "hey.com", "zoho.com", "qq.com", "163.com",
    ]

    public static func domain(of email: String) -> String? {
        let normalized = PersonMatching.normalizedEmail(email)
        guard let at = normalized.firstIndex(of: "@") else { return nil }
        let domain = String(normalized[normalized.index(after: at)...])
        return domain.isEmpty ? nil : domain
    }

    /// A public domain, or any subdomain of one.
    public static func isPublicDomain(_ domain: String, extra: Set<String>) -> Bool {
        let stop = builtInStopDomains.union(extra.map { $0.lowercased() })
        let lower = domain.lowercased()
        return stop.contains(lower) || stop.contains { lower.hasSuffix("." + $0) }
    }

    public static func suggestions(
        for person: Person, domainAddressCounts: [String: Int], existing: [Person], preferences: PersonsPreferences
    ) -> [OrganizationSuggestion] {
        guard person.kind == .person else { return [] }
        var result: [OrganizationSuggestion] = []
        if preferences.companyRuleEnabled {
            let company = person.organization.trimmingCharacters(in: .whitespacesAndNewlines)
            if !company.isEmpty {
                let source =
                    person.observations.filter { $0.field == "organization" && $0.value == company }.map(\.source.identity).first
                    .map { ImportSource(service: $0.service, accountID: $0.accountID) }
                    ?? ImportSource(service: "manual", accountID: "local")
                result.append(
                    OrganizationSuggestion(
                        organizationName: company, existingOrganizationID: existingOrganization(named: company, in: existing)?.id,
                        origin: .companyField(source), role: person.jobTitle))
            }
        }
        if preferences.domainRuleEnabled {
            var seen = Set<String>()
            for email in person.emails {
                guard let domain = domain(of: email), seen.insert(domain).inserted,
                    !isPublicDomain(domain, extra: Set(preferences.extraStopDomains)), domainAddressCounts[domain, default: 0] >= 2
                else { continue }
                result.append(
                    OrganizationSuggestion(
                        organizationName: domain, existingOrganizationID: existingOrganization(named: domain, in: existing)?.id,
                        origin: .emailDomain(domain), role: ""))
            }
        }
        return result
    }

    static func existingOrganization(named name: String, in existing: [Person]) -> Person? {
        existing.first {
            $0.kind == .organization && $0.displayName.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
        }
    }
}
