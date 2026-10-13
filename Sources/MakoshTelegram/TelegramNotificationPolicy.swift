import Foundation

public enum TelegramNotificationCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case personal, groups, channels
    public var id: String { rawValue }
}
public enum TelegramNotificationSound: String, Codable, CaseIterable, Sendable { case system, none }
public struct TelegramNotificationRule: Codable, Equatable, Sendable {
    public var enabled: Bool? = nil
    public var previews: Bool? = nil
    public var sound: TelegramNotificationSound? = nil
    public init(enabled: Bool? = nil, previews: Bool? = nil, sound: TelegramNotificationSound? = nil) {
        self.enabled = enabled; self.previews = previews; self.sound = sound
    }
}
public struct TelegramNotificationPreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public var previews = true
    public var sound = TelegramNotificationSound.system
    public var bounce = false
    public var suppressWhileActive = true
    public var snoozeUntil: Date? = nil
    public var badgeEnabled = true
    public var badgeGroups = true
    public var badgeChannels = true
    public var countMessages = true
    public var categories: [TelegramNotificationCategory: TelegramNotificationRule] = [:]
    public var peers: [Int64: TelegramNotificationRule] = [:]
    public init() {}
}
struct TelegramNotificationEvent: Equatable, Sendable {
    let accountID: Int64
    let peerID: Int64
    let namespace: Int32
    let messageID: Int32
    let threadID: Int64?
    let timestamp: Int32
    let category: TelegramNotificationCategory
    let title: String
    let text: TelegramFormattedText?
    let fallback: String
    let incoming: Bool
    let serverNotify: Bool
    let serverPreviews: Bool
    let serverSilent: Bool
    let secret: Bool
    let protected: Bool
    let serviceCodes: Bool
    var groupingKey: Int64? = nil
    var identity: String { "\(accountID):\(peerID):\(namespace):" + (groupingKey.map { "group:\($0)" } ?? "message:\(messageID)") }
}
struct TelegramNotificationEnvironment: Sendable {
    var active = false
    var locked = false
    var now = Date()
}
struct TelegramNotificationContent: Equatable, Sendable {
    let title: String
    let body: String
    let sound: Bool
    let bounce: Bool
}
@MainActor func telegramNotificationContent(_ event: TelegramNotificationEvent,
    preferences: TelegramNotificationPreferences, environment: TelegramNotificationEnvironment) -> TelegramNotificationContent? {
    let now = environment.now.timeIntervalSince1970
    guard event.incoming, event.serverNotify, event.messageID > 0, event.peerID != 0,
          now.isFinite, Double(event.timestamp) >= now - 86_400, Double(event.timestamp) <= now + 60,
          preferences.enabled, preferences.snoozeUntil.map({ $0 <= environment.now }) ?? true,
          !(preferences.suppressWhileActive && environment.active) else { return nil }
    let category = preferences.categories[event.category] ?? .init()
    let peer = preferences.peers[event.peerID] ?? .init()
    guard peer.enabled ?? category.enabled ?? true else { return nil }
    let previews = preferences.previews && (peer.previews ?? category.previews ?? true) && event.serverPreviews
    let hidden = !previews || environment.locked || event.secret || event.protected
    var body = hidden ? "Новое сообщение" : event.text.map { TelegramMessagePresentation.plainText($0) } ?? event.fallback
    if body.isEmpty { body = event.fallback }
    if !hidden && event.serviceCodes, let regex = try? NSRegularExpression(pattern: #"[\d\-]{3,7}"#) {
        let mutable = NSMutableString(string: body)
        for match in regex.matches(in: body, range: NSRange(location: 0, length: mutable.length)).reversed() {
            mutable.replaceCharacters(in: match.range, with: String(repeating: "█", count: match.range.length))
        }
        body = mutable as String
    }
    func bounded(_ value: String, limit: Int) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }
            .map(String.init).joined().prefix(limit))
    }
    let title = environment.locked ? "Telegram" : bounded(event.title, limit: 128)
    let sound = peer.sound ?? category.sound ?? preferences.sound
    return .init(title: title.isEmpty ? "Telegram" : title, body: bounded(body.isEmpty ? "Новое сообщение" : body, limit: 512),
                 sound: sound == .system && !event.serverSilent && !environment.locked,
                 bounce: preferences.bounce && !environment.locked)
}
