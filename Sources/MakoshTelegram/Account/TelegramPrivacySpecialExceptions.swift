import Foundation

extension TelegramPrivacySetting {
    public var editableSpecialException: TelegramPrivacyRule? {
        switch kind { case .groupInvitations: .premium; case .giftsAutoSave: .bots; default: nil }
    }
    public func replacingSpecialException(_ rule: TelegramPrivacyRule, enabled: Bool) -> TelegramPrivacySetting? {
        guard isValid, audience != nil, editableSpecialException == rule,
              rules.filter({ $0 == rule }).count <= 1, rules.contains(rule) != enabled else { return nil }
        var updated = rules.filter { $0 != rule }
        if enabled {
            guard let base = updated.firstIndex(where: \.isBase) else { return nil }
            updated.insert(rule, at: base)
        }
        let result = TelegramPrivacySetting(kind: kind, rules: updated)
        return result.isValid ? result : nil
    }
    func permitsSpecialChanges(to other: TelegramPrivacySetting) -> Bool {
        let old = rules.filter(\.isSpecial), new = other.rules.filter(\.isSpecial)
        guard old != new else { return true }
        guard let editable = editableSpecialException,
              old.filter({ $0 != editable }) == new.filter({ $0 != editable }),
              old.filter({ $0 == editable }).count <= 1, new.filter({ $0 == editable }).count <= 1,
              old.contains(editable) != new.contains(editable) else { return false }
        if let position = other.rules.firstIndex(of: editable), let base = other.rules.firstIndex(where: \.isBase), position >= base { return false }
        return true
    }
}
