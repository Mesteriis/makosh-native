import Foundation
import Combine
import SwiftSignalKit

public struct TelegramNotificationDelivery: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let sound: Bool
    public let bounce: Bool
    public let sourceKey: String?
    public init(id: String, title: String, body: String, sound: Bool, bounce: Bool, sourceKey: String? = nil) {
        self.id = id; self.title = title; self.body = body; self.sound = sound; self.bounce = bounce; self.sourceKey = sourceKey
    }
}
public struct TelegramNotificationUnreadCount: Equatable, Sendable {
    public let messages: Int
    public let chats: Int
    public init(messages: Int, chats: Int) { self.messages = messages; self.chats = chats }
}
@MainActor public final class TelegramNotificationController: ObservableObject {
    @Published public private(set) var preferences = TelegramNotificationPreferences()
    @Published public private(set) var delivery: TelegramNotificationDelivery?
    @Published public private(set) var badgeCount = 0
    @Published public private(set) var contextID = UUID()
    @Published public private(set) var accountID: Int64?
    @Published public private(set) var error: String?
    @Published public private(set) var deliveryWarning: String?
    @Published public private(set) var activationRequest = UUID()
    @Published public private(set) var clearRequest = UUID()
    var environment: () -> TelegramNotificationEnvironment = { .init() }
    var didActivate: ((TelegramNotificationEvent) -> Bool)?
    private let defaults: UserDefaults
    private struct Stored: Codable { let version: Int; let accountID: Int64; let preferences: TelegramNotificationPreferences }
    private var seen = Set<String>(), seenOrder: [String] = []
    private var routes: [String: TelegramNotificationEvent] = [:]
    private var routeOrder: [String] = []
    private var unread: [TelegramNotificationCategory: TelegramNotificationUnreadCount] = [:]
    private var locked = false
    private var preferencesObserver: NSObjectProtocol?
    private static let preferencesChanged = Notification.Name("org.makosh.telegram.notificationPreferencesChanged")
    let source = MetaDisposable()
    public var notificationIdentifiers: Set<String> { Set(routes.keys) }
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferencesObserver = NotificationCenter.default.addObserver(forName: Self.preferencesChanged, object: nil, queue: .main) { [weak self] event in
            guard let other = event.object as? TelegramNotificationController else { return }
            MainActor.assumeIsolated {
                guard let self, other !== self,
                      other.defaults === self.defaults, self.accountID != nil, self.accountID == other.accountID else { return }
                self.loadPreferences(); self.invalidateDeliveredNotifications(); self.updateBadge()
            }
        }
    }
    isolated deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        source.dispose()
    }
    private func key(_ account: Int64) -> String { "telegram.notifications.v1.\(account)" }
    func bind(accountID: Int64?) {
        source.set(nil)
        invalidateDeliveredNotifications(); contextID = UUID()
        self.accountID = accountID; unread = [:]; badgeCount = 0; error = nil; deliveryWarning = nil
        loadPreferences()
    }
    private func loadPreferences() {
        preferences = .init()
        error = nil
        guard let accountID else { return }
        if let data = defaults.data(forKey: key(accountID)) {
            guard data.count <= 65_536, let stored = try? JSONDecoder().decode(Stored.self, from: data),
                  stored.version == 1, stored.accountID == accountID, valid(stored.preferences) else {
                preferences.enabled = false
                error = "Локальные настройки уведомлений недоступны. Сбросьте их явно; до этого уведомления выключены."
                return
            }
            preferences = stored.preferences
        } else if defaults.object(forKey: key(accountID)) != nil {
            preferences.enabled = false
            error = "Локальные настройки уведомлений недоступны. Сбросьте их явно; до этого уведомления выключены."
        }
    }
    private func valid(_ value: TelegramNotificationPreferences) -> Bool {
        value.peers.count <= 512 && value.peers.keys.allSatisfy { $0 != 0 } &&
            (value.snoozeUntil.map { $0.timeIntervalSince1970.isFinite } ?? true)
    }
    @discardableResult public func update(_ value: TelegramNotificationPreferences, contextID: UUID) -> Bool {
        guard error == nil else { return false }
        return save(value, contextID: contextID)
    }
    @discardableResult private func save(_ value: TelegramNotificationPreferences, contextID: UUID) -> Bool {
        guard self.contextID == contextID, let accountID, valid(value),
              let data = try? JSONEncoder().encode(Stored(version: 1, accountID: accountID, preferences: value)),
              data.count <= 65_536 else { return false }
        defaults.set(data, forKey: key(accountID))
        preferences = value; error = nil
        invalidateDeliveredNotifications(); updateBadge()
        NotificationCenter.default.post(name: Self.preferencesChanged, object: self)
        return true
    }
    @discardableResult public func reset(contextID: UUID) -> Bool { save(.init(), contextID: contextID) }
    func receive(_ event: TelegramNotificationEvent, contextID: UUID) {
        guard self.contextID == contextID, accountID == event.accountID, !seen.contains(event.identity),
              event.text.map({ $0.text.utf8.count <= 65_536 }) ?? true else { return }
        seen.insert(event.identity); seenOrder.append(event.identity)
        if seenOrder.count > 4096 { seen.remove(seenOrder.removeFirst()) }
        guard let content = telegramNotificationContent(event, preferences: preferences, environment: environment()) else { return }
        let id = UUID().uuidString
        routes[id] = event; routeOrder.append(id)
        if routeOrder.count > 100 { routes.removeValue(forKey: routeOrder.removeFirst()) }
        delivery = .init(id: id, title: content.title, body: content.body, sound: content.sound, bounce: content.bounce, sourceKey: event.identity)
    }
    func receiveUnread(_ counts: [TelegramNotificationCategory: TelegramNotificationUnreadCount], contextID: UUID) {
        guard self.contextID == contextID, accountID != nil else { return }
        guard counts.values.allSatisfy({ (0...Int(Int32.max)).contains($0.messages) && (0...Int(Int32.max)).contains($0.chats) }) else {
            unread = [:]; badgeCount = 0; return
        }
        unread = counts; updateBadge()
    }
    func reportOverflow(contextID: UUID) {
        guard self.contextID == contextID, accountID != nil else { return }
        deliveryWarning = "Часть уведомлений пропущена: слишком большая очередь. Сообщения в переписке сохранены."
    }
    private func updateBadge() {
        guard accountID != nil, preferences.badgeEnabled else { badgeCount = 0; return }
        let categories: [TelegramNotificationCategory] = [.personal] + (preferences.badgeGroups ? [.groups] : []) + (preferences.badgeChannels ? [.channels] : [])
        badgeCount = min(999_999, categories.reduce(0) { result, category in
            result + ((preferences.countMessages ? unread[category]?.messages : unread[category]?.chats) ?? 0)
        })
    }
    @discardableResult public func activate(identifier: String) -> Bool {
        guard let event = routes.removeValue(forKey: identifier), event.accountID == accountID, preferences.enabled,
              didActivate?(event) == true else { return false }
        routeOrder.removeAll { $0 == identifier }
        activationRequest = UUID(); return true
    }
    public func canPresent(identifier: String) -> Bool {
        guard let event = routes[identifier], event.accountID == accountID else { return false }
        return telegramNotificationContent(event, preferences: preferences, environment: environment()) != nil
    }
    public func setPresentationEnvironment(active: Bool, locked: Bool) {
        if locked && !self.locked { invalidateDeliveredNotifications() }
        self.locked = locked
        environment = { .init(active: active, locked: locked) }
    }
    public func invalidateDeliveredNotifications() {
        routes = [:]; routeOrder = []; delivery = nil; clearRequest = UUID()
    }
}
