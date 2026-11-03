import Foundation
import TelegramApi

public struct TelegramPrivacyCapabilities: Equatable, Sendable {
    public let isPremium: Bool
    public let nonPremiumMessageRestrictionAvailable: Bool
    public let paidMessagesAvailable: Bool
    public let maximumPaidStars: Int64
    public var canRestrictIncomingMessages: Bool { isPremium || nonPremiumMessageRestrictionAvailable }
}
public enum TelegramIncomingMessagePolicy: Equatable, Sendable { case everybody, contactsAndPremium, paidStars(Int64) }
public enum TelegramGiftKind: Int32, CaseIterable, Identifiable, Sendable {
    case unlimited = 1, limited = 2, unique = 4, premium = 8
    public var id: Int32 { rawValue }
}
public enum TelegramGlobalPrivacyEdit: Equatable, Sendable {
    case hideReadTime(Bool), messagePolicy(TelegramIncomingMessagePolicy), allowGift(TelegramGiftKind, Bool)
}
public struct TelegramGlobalPrivacySetting: Equatable, Sendable {
    let flags: Int32
    let paidStars: Int64?
    let giftFlags: Int32?
    init(flags: Int32, paidStars: Int64?, giftFlags: Int32?) { self.flags = flags; self.paidStars = paidStars; self.giftFlags = giftFlags }
    init?(_ native: Api.GlobalPrivacySettings) {
        guard case let .globalPrivacySettings(flags, stars, gifts) = native else { return nil }
        self.flags = flags; paidStars = stars
        if case let .disallowedGiftsSettings(value) = gifts { giftFlags = value } else { giftFlags = nil }
        guard isValid else { return nil }
    }
    var api: Api.GlobalPrivacySettings? {
        guard isValid else { return nil }
        return .globalPrivacySettings(flags: flags, noncontactPeersPaidStars: paidStars,
            disallowedGifts: giftFlags.map { .disallowedGiftsSettings(flags: $0) })
    }
    var isValid: Bool {
        (flags & (1 << 5) != 0) == (paidStars != nil) && (paidStars ?? 0) >= 0 &&
        (flags & (1 << 6) != 0) == (giftFlags != nil)
    }
    public var hideReadTime: Bool { flags & (1 << 3) != 0 }
    public var messagePolicy: TelegramIncomingMessagePolicy {
        if let paidStars, paidStars > 0 { return .paidStars(paidStars) }
        return flags & (1 << 4) != 0 ? .contactsAndPremium : .everybody
    }
    public func allowsGift(_ kind: TelegramGiftKind) -> Bool { (giftFlags ?? 0) & kind.rawValue == 0 }
    public func replacing(_ edit: TelegramGlobalPrivacyEdit) -> TelegramGlobalPrivacySetting? {
        guard isValid else { return nil }
        var flags = flags, stars = paidStars, gifts = giftFlags
        switch edit {
        case let .hideReadTime(value): flags = value ? flags | (1 << 3) : flags & ~(1 << 3)
        case let .messagePolicy(value):
            flags &= ~((1 << 4) | (1 << 5)); stars = nil
            switch value {
            case .everybody: flags |= 1 << 5; stars = 0
            case .contactsAndPremium: flags |= 1 << 4
            case let .paidStars(amount): guard amount > 0 else { return nil }; flags |= 1 << 5; stars = amount
            }
        case let .allowGift(kind, allowed):
            flags |= 1 << 6
            gifts = allowed ? (gifts ?? 0) & ~kind.rawValue : (gifts ?? 0) | kind.rawValue
        }
        let result = TelegramGlobalPrivacySetting(flags: flags, paidStars: stars, giftFlags: gifts)
        return result == self ? nil : result
    }
}
public struct TelegramGlobalPrivacyChange: Equatable, Sendable {
    public let expected: TelegramGlobalPrivacySetting
    public let proposed: TelegramGlobalPrivacySetting
    public init(expected: TelegramGlobalPrivacySetting, proposed: TelegramGlobalPrivacySetting) { self.expected = expected; self.proposed = proposed }
    public func replacement(capabilities: TelegramPrivacyCapabilities) -> TelegramGlobalPrivacySetting? {
        let editable: Int32 = (1 << 3) | (1 << 4) | (1 << 5) | (1 << 6)
        guard expected.isValid, proposed.isValid, proposed != expected,
              (expected.flags ^ proposed.flags) & ~editable == 0,
              ((expected.giftFlags ?? 0) ^ (proposed.giftFlags ?? 0)) & ~Int32(15) == 0 else { return nil }
        if expected.giftFlags != proposed.giftFlags || (expected.flags ^ proposed.flags) & (1 << 6) != 0 {
            guard capabilities.isPremium else { return nil }
        }
        if expected.paidStars != proposed.paidStars || (expected.flags ^ proposed.flags) & ((1 << 4) | (1 << 5)) != 0 {
            switch proposed.messagePolicy {
            case .everybody: break
            case .contactsAndPremium: guard capabilities.canRestrictIncomingMessages else { return nil }
            case let .paidStars(amount):
                guard capabilities.canRestrictIncomingMessages, capabilities.paidMessagesAvailable,
                      amount > 0, amount <= capabilities.maximumPaidStars else { return nil }
            }
        }
        return proposed
    }
}
