#if DEBUG
import Foundation

@MainActor func telegramSyntheticPeerProfile(chat: TelegramChat, accountID: Int64) -> TelegramContactProfile {
    let number = chat.id % 10_000
    let kind: TelegramContactProfile.Kind = switch number {
    case 2: .group
    case 3, 6: .channel
    case 4, 7: .supergroup
    case 5: .bot
    default: .person
    }
    let memberCount: Int? = switch kind {
    case .group: 12
    case .supergroup: number == 7 ? 0 : 1_234
    case .channel: number == 6 ? nil : 50_000
    default: nil
    }
    return TelegramContactProfile(accountID: accountID, peerID: chat.id, displayName: chat.title,
        username: kind == .group ? nil : "synthetic_\(chat.id)", phone: kind == .person ? "10000000000" : nil,
        kind: kind, about: number == 6 || number == 7 ? nil : "Синтетическое описание диалога \(number). Личные данные не используются.",
        memberCount: memberCount,
        isScam: number == 6, isFake: number == 7, observedAt: Date())
}
#endif
