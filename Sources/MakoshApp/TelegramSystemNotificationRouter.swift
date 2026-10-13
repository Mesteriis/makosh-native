import AppKit
import UserNotifications
import Combine
import MakoshTelegram

/// One delegate per application; each workspace retains its own model/window.
@MainActor final class TelegramSystemNotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    let registry = TelegramNotificationRegistry()
    private var badgeObservation: AnyCancellable?
    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        badgeObservation = registry.$badgeCount.sink { count in NSApp.dockTile.badgeLabel = count == 0 ? nil : String(count) }
    }
    var systemIdentifiers: Set<String> { Set(registry.identifiers.map { "makosh.telegram." + $0 }) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        Task { @MainActor [weak self] in
            let prefix = "makosh.telegram."
            let admitted = identifier.hasPrefix(prefix) && self?.registry.canPresent(identifier: String(identifier.dropFirst(prefix.count))) == true
            completionHandler(admitted ? [.banner, .list, .sound] : [])
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let identifier = response.notification.request.identifier, action = response.actionIdentifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            let prefix = "makosh.telegram."
            guard action == UNNotificationDefaultActionIdentifier, identifier.hasPrefix(prefix) else { return }
            self?.registry.activate(identifier: String(identifier.dropFirst(prefix.count)))
        }
    }
}
