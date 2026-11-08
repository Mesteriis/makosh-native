import Foundation

/// Normalization behind the value index, duplicate review and automatic merging.
public enum PersonMatching {
    /// Digits only; a Russian trunk `8` on an eleven-digit number becomes `7`; fewer than seven digits is no phone.
    public static func normalizedPhone(_ value: String) -> String {
        var digits = value.filter { $0.isASCII && $0.isNumber }
        if digits.count == 11, digits.first == "8" { digits = "7" + digits.dropFirst() }
        return digits.count < 7 ? "" : digits
    }

    /// Lower case without surrounding spaces; a string without `@` is no address.
    public static func normalizedEmail(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.contains("@") ? trimmed : ""
    }

    /// Local parts shared by whole teams or robots: they never make two persons one.
    public static let roleLocalParts: Set<String> = [
        "info", "office", "support", "sales", "admin", "hello", "contact", "mail", "help", "team",
        "noreply", "no-reply", "donotreply", "postmaster", "mailer-daemon", "notifications", "bounce",
    ]

    public static func isRoleAddress(_ email: String) -> Bool {
        let normalized = normalizedEmail(email)
        guard let at = normalized.firstIndex(of: "@") else { return false }
        return roleLocalParts.contains(String(normalized[..<at]))
    }

    public static func normalized(_ field: PersonListField, _ value: String) -> String {
        switch field {
        case .phones: normalizedPhone(value)
        case .emails: normalizedEmail(value)
        case .usernames, .tags: ""
        }
    }

    /// The rows the value index holds for a person: active persons only, phones and e-mails only.
    static func indexRows(_ person: Person) -> [(field: String, normalized: String, raw: String)] {
        guard person.isActive else { return [] }
        var seen = Set<String>()
        var rows: [(String, String, String)] = []
        for field in [PersonListField.phones, .emails] {
            for raw in person.values(field) {
                let normalized = normalized(field, raw)
                guard !normalized.isEmpty, seen.insert(field.rawValue + "|" + normalized).inserted else { continue }
                rows.append((field.rawValue, normalized, raw))
            }
        }
        return rows
    }
}
