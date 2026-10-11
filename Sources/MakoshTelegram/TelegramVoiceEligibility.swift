import Postbox
import TelegramCore

func telegramVoiceOnceEligibility(peer: Peer?, cachedData: CachedPeerData?, accountID: Int64, now: Int32) -> TelegramVoiceEligibility {
    guard let user = peer as? TelegramUser, user.id.namespace == Namespaces.Peer.CloudUser,
        user.id.toInt64() != accountID, user.botInfo == nil else { return .restricted }
    let ordinary = telegramVoiceEligibility(peer: peer, cachedData: cachedData, now: now, hasPendingMessages: false)
    guard ordinary == .allowed else { return ordinary }
    // The pinned native recorder excludes even an explicit zero-price context.
    guard let cache = cachedData as? CachedUserData else { return .unavailable }
    return cache.sendPaidMessageStars == nil ? .allowed : .paid
}

public enum TelegramVoiceEligibility: Equatable, Sendable {
    case allowed
    case unavailable
    case restricted
    case voicePrivacy
    case slowMode(until: Int32?)
    case paid

    public var explanation: String? {
        switch self {
        case .allowed: return nil
        case .unavailable: return "Не удалось проверить возможность отправки голосового сообщения."
        case .restricted: return "В этом чате запрещена отправка голосовых сообщений."
        case .voicePrivacy: return "Собеседник запретил отправку голосовых сообщений."
        case .slowMode: return "В чате действует медленный режим. Дождитесь завершения предыдущей отправки."
        case .paid: return "Для отправки в этот чат требуется подтверждение оплаты звёздами."
        }
    }
}

/// Evaluate a fresh, same-peer Postbox snapshot before capture and again before
/// handing recorded PCM to the upload controller. This does not authorize a fee.
func telegramVoiceEligibility(peer: Peer?, cachedData: CachedPeerData?, now: Int32,
    hasPendingMessages: Bool) -> TelegramVoiceEligibility {
    if let user = peer as? TelegramUser, user.id.namespace == Namespaces.Peer.CloudUser {
        guard let cache = cachedData as? CachedUserData else { return .unavailable }
        guard !cache.isBlocked else { return .restricted }
        guard cache.voiceMessagesAvailable else { return .voicePrivacy }
        if let fee = cache.sendPaidMessageStars {
            if fee != .zero { return .paid }
        } else if user.flags.contains(.requireStars) {
            return .paid
        }
        return .allowed
    }
    if let group = peer as? TelegramGroup, group.id.namespace == Namespaces.Peer.CloudGroup {
        guard cachedData == nil || cachedData is CachedGroupData else { return .unavailable }
        guard group.migrationReference == nil else { return .unavailable }
        guard group.membership == .Member, !group.flags.contains(.deactivated),
            group.defaultBannedRights?.flags.contains(.banReadMessages) != true else { return .restricted }
        guard group.hasPermission(.sendSomething), !group.hasBannedPermission(.banSendVoice),
            !group.hasBannedPermission(.banSendMedia) else { return .restricted }
        return .allowed
    }
    guard let channel = peer as? TelegramChannel, channel.id.namespace == Namespaces.Peer.CloudChannel,
        let cache = cachedData as? CachedChannelData else { return .unavailable }
    // Channel direct-message threads require separate topic/fee context.
    guard !channel.flags.contains(.isMonoforum) else { return .unavailable }
    guard channel.participationStatus == .member, !cache.isNotAccessible,
        channel.bannedRights?.flags.contains(.banReadMessages) != true,
        channel.defaultBannedRights?.flags.contains(.banReadMessages) != true else { return .restricted }

    let admin = channel.flags.contains(.isCreator) || channel.adminRights != nil
    let group: Bool
    switch channel.info {
    case .group: group = true
    case .broadcast: group = false
    }
    let boosted: Bool
    if group, let required = cache.boostsToUnrestrict, required > 0,
        let applied = cache.appliedBoosts, applied >= required {
        boosted = true
    } else {
        boosted = false
    }
    guard channel.hasPermission(.sendSomething) || boosted else { return .restricted }
    if !boosted, channel.hasBannedPermission(.banSendVoice) != nil
        || channel.hasBannedPermission(.banSendMedia) != nil {
        return .restricted
    }
    if !admin, let fee = cache.sendPaidMessageStars ?? channel.sendPaidMessageStars, fee != .zero {
        return .paid
    }
    if channel.isRestrictedBySlowmode {
        guard let timeout = cache.slowModeTimeout, timeout > 0 else { return .unavailable }
        if let until = cache.slowModeValidUntilTimestamp, until > now { return .slowMode(until: until) }
        if hasPendingMessages { return .slowMode(until: nil) }
    }
    return .allowed
}
