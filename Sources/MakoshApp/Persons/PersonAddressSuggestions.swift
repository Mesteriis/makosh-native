import Foundation
import MakoshCore

/// Addressees the mail composer offers under «Кому»: active persons whose name or address contains what was typed.
enum PersonAddressSuggestions {
    static let minimumLength = 2
    static let limit = 6

    static func suggestions(typed: String, persons: [PersonSummary], emails: [UUID: [String]]) -> [(address: String, name: String)] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= minimumLength else { return [] }
        var seen = Set<String>()
        var result: [(address: String, name: String)] = []
        for person in persons where person.isActive {
            let known = emails[person.id] ?? []
            let addresses = known.isEmpty ? [person.firstEmail].compactMap { $0 } : known
            let nameMatches = person.displayName.lowercased().contains(needle)
            for address in addresses where nameMatches || address.lowercased().contains(needle) {
                guard seen.insert(address.lowercased()).inserted else { continue }
                result.append((address: address, name: person.displayName))
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// The piece after the last comma: what the person is typing now.
    static func fragment(of field: String) -> String {
        guard let comma = field.lastIndex(of: ",") else { return field.trimmingCharacters(in: .whitespaces) }
        return field[field.index(after: comma)...].trimmingCharacters(in: .whitespaces)
    }

    /// Replaces the typed fragment with `Имя <адрес>` (the bare address without a name) and opens the next slot.
    static func insert(address: String, name: String, into field: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let recipient = trimmed.isEmpty || trimmed.caseInsensitiveCompare(address) == .orderedSame ? address : "\(trimmed) <\(address)>"
        let head = field.lastIndex(of: ",").map { String(field[...$0]) + " " } ?? ""
        return head + recipient + ", "
    }
}
