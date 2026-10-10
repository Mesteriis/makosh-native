import Foundation
import TelegramCore
import Postbox

public struct TelegramPeerStatusPresentation: Equatable, Sendable {
    public let text: String
    public let isOnline: Bool
    public let nextRefresh: Date?
}

/// A cached, selected-account observation. Offset is server time minus device time.
public struct TelegramPeerStatus: Equatable, Sendable {
    public enum Presence: Equatable, Sendable {
        case none, present(until: Int32), recently(isHidden: Bool), lastWeek(isHidden: Bool), lastMonth(isHidden: Bool)
    }
    public let accountID: Int64
    public let peerID: Int64
    public let kind: TelegramContactProfile.Kind
    public let presence: Presence?
    public let lastActivity: Int32
    public let memberCount: Int?
    public let isSelf: Bool
    public let isSupport: Bool
    public let isService: Bool
    public let serverTimeOffset: TimeInterval
    public init(accountID: Int64, peerID: Int64, kind: TelegramContactProfile.Kind,
                presence: Presence? = nil, lastActivity: Int32 = 0, memberCount: Int? = nil,
                isSelf: Bool = false, isSupport: Bool = false, isService: Bool = false, serverTimeOffset: TimeInterval = 0) {
        self.accountID = accountID; self.peerID = peerID; self.kind = kind
        self.presence = presence; self.lastActivity = lastActivity
        self.memberCount = memberCount.flatMap { $0 >= 0 ? $0 : nil }
        self.isSelf = isSelf; self.isSupport = isSupport; self.isService = isService
        self.serverTimeOffset = serverTimeOffset
    }
    public func presentation(now: Date, timeZone: TimeZone = .current) -> TelegramPeerStatusPresentation {
        func result(_ text: String, online: Bool = false, refresh: Date? = nil) -> TelegramPeerStatusPresentation {
            TelegramPeerStatusPresentation(text: text, isOnline: online, nextRefresh: refresh)
        }
        if isSelf { return result("") }
        if isService { return result("Служебные уведомления") }
        if isSupport { return result("Поддержка Telegram") }
        if kind == .bot { return result("Бот") }
        if kind != .person {
            guard let memberCount else { return result(kind == .channel ? "Канал" : "Группа") }
            let forms = kind == .channel ? ["подписчик", "подписчика", "подписчиков"] : ["участник", "участника", "участников"]
            let lastTwo = memberCount % 100, last = memberCount % 10
            let form = (11...14).contains(lastTwo) ? 2 : (last == 1 ? 0 : ((2...4).contains(last) ? 1 : 2))
            return result("\(memberCount) \(forms[form])")
        }
        let timestamp = now.timeIntervalSince1970 + serverTimeOffset
        guard timestamp.isFinite, serverTimeOffset.isFinite else { return result("Статус недоступен") }
        switch presence {
        case nil: return result("Статус недоступен")
        case .none?: return result("Был(а) давно")
        case let .present(until)?:
            let expiry = Double(until)
            if expiry > timestamp { return result("В сети", online: true, refresh: Date(timeIntervalSince1970: expiry - serverTimeOffset)) }
            let elapsed = timestamp - expiry
            if elapsed < 59 { return result("Был(а) только что", refresh: Date(timeIntervalSince1970: expiry + 59 - serverTimeOffset)) }
            if elapsed < 3600 {
                let minutes = max(1, Int(elapsed / 60))
                return result("Был(а) \(minutes) мин. назад", refresh: Date(timeIntervalSince1970: expiry + Double((minutes + 1) * 60) - serverTimeOffset))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timeZone
            formatter.dateFormat = "dd.MM.yyyy HH:mm"
            return result("Был(а) " + formatter.string(from: Date(timeIntervalSince1970: expiry)))
        case .recently?:
            let activeUntil = Double(lastActivity) + 30
            if lastActivity > 0, activeUntil > timestamp {
                return result("В сети", online: true, refresh: Date(timeIntervalSince1970: activeUntil - serverTimeOffset))
            }
            return result("Был(а) недавно")
        case .lastWeek?: return result("Был(а) на этой неделе")
        case .lastMonth?: return result("Был(а) в этом месяце")
        }
    }
}

func telegramPeerStatus(peer: Peer, presence: PeerPresence?, cachedData: CachedPeerData?, accountID: Int64,
                        serverTimeOffset: TimeInterval) -> TelegramPeerStatus? {
    guard let profile = telegramContactProfile(peer: peer, accountID: accountID, observedAt: Date(timeIntervalSince1970: 0), cachedData: cachedData) else { return nil }
    let native = presence as? TelegramUserPresence
    let mapped: TelegramPeerStatus.Presence?
    switch native?.status {
    case nil: mapped = nil
    case .none?: mapped = .some(.none)
    case let .present(until)?: mapped = .present(until: until)
    case let .recently(hidden)?: mapped = .recently(isHidden: hidden)
    case let .lastWeek(hidden)?: mapped = .lastWeek(isHidden: hidden)
    case let .lastMonth(hidden)?: mapped = .lastMonth(isHidden: hidden)
    }
    let user = peer as? TelegramUser
    return TelegramPeerStatus(accountID: accountID, peerID: peer.id.toInt64(), kind: profile.kind,
        presence: mapped, lastActivity: native?.lastActivity ?? 0, memberCount: profile.memberCount,
        isSelf: peer.id.toInt64() == accountID, isSupport: user?.flags.contains(.isSupport) == true,
        isService: user?.phone.map { ["42777", "42470", "4240004"].contains($0) } == true,
        serverTimeOffset: serverTimeOffset)
}
