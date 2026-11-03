import AppKit
import UserNotifications
import Combine
import MakoshTelegram
import MakoshMail

/// One delegate per application; each workspace retains its own model/window.
@MainActor final class ApplicationSystemNotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    let registry = TelegramNotificationRegistry()
    let mailRegistry = MailNotificationRegistry()
    let whatsappRegistry = WhatsAppNotificationRegistry()
    let teamsRegistry = TeamsNotificationRegistry()
    var authorizationAttempted = false
    @Published private(set) var authorizationRequesting = false
    func beginAuthorizationRequest() -> Bool {
        guard !authorizationRequesting else { return false }
        authorizationAttempted = true; authorizationRequesting = true; return true
    }
    func finishAuthorizationRequest() { authorizationRequesting = false }
    nonisolated static let mailCategory = "makosh.mail.incoming"
    nonisolated static let mailArchive = "makosh.mail.archive", mailTrash = "makosh.mail.trash"
    private var badgeObservation: AnyCancellable?
    init(registerSystemDelegate: Bool = true) {
        super.init()
        if registerSystemDelegate {
            let center = UNUserNotificationCenter.current();center.delegate = self
            let category = UNNotificationCategory(identifier:Self.mailCategory,actions:[
                .init(identifier:Self.mailArchive,title:"Архив",options:[.foreground]),
                .init(identifier:Self.mailTrash,title:"Корзина",options:[.foreground,.destructive])],intentIdentifiers:[],options:[])
            center.getNotificationCategories { categories in center.setNotificationCategories(categories.union([category])) }
        }
        badgeObservation = registry.$badgeCount.sink { count in NSApp?.dockTile.badgeLabel = count == 0 ? nil : String(count) }
    }
    var systemIdentifiers: Set<String> { Set(registry.identifiers.map { "makosh.telegram." + $0 }).union(mailRegistry.identifiers.map { "makosh.mail." + $0 }).union(whatsappRegistry.identifiers.map { "makosh.whatsapp." + $0 }).union(teamsRegistry.identifiers.map { "makosh.teams." + $0 }) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        Task { @MainActor [weak self] in
            let prefix = "makosh.telegram."
            let admitted:Bool
            if identifier.hasPrefix("makosh.teams.") { admitted = await self?.teamsRegistry.canPresent(String(identifier.dropFirst("makosh.teams.".count))) == true }
            else if identifier.hasPrefix("makosh.whatsapp.") { admitted = await self?.whatsappRegistry.canPresent(String(identifier.dropFirst("makosh.whatsapp.".count))) == true }
            else if identifier.hasPrefix("makosh.mail.") { admitted = self?.mailRegistry.canPresent(identifier:String(identifier.dropFirst("makosh.mail.".count))) == true }
            else { admitted = identifier.hasPrefix(prefix) && self?.registry.canPresent(identifier: String(identifier.dropFirst(prefix.count))) == true }
            completionHandler(admitted ? [.banner, .list, .sound] : [])
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let identifier = response.notification.request.identifier, action = response.actionIdentifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            let prefix = "makosh.telegram."
            if identifier.hasPrefix("makosh.teams.") { if action == UNNotificationDefaultActionIdentifier { await self?.teamsRegistry.activate(String(identifier.dropFirst("makosh.teams.".count))) }; return }
            if identifier.hasPrefix("makosh.whatsapp.") {if action == UNNotificationDefaultActionIdentifier{await self?.whatsappRegistry.activate(String(identifier.dropFirst("makosh.whatsapp.".count)))};return}
            if identifier.hasPrefix("makosh.mail.") {
                let resolved:MailNotificationAction?
                switch action { case UNNotificationDefaultActionIdentifier: resolved = .open;case Self.mailArchive: resolved = .archive;case Self.mailTrash: resolved = .trash;default: resolved = nil }
                if let resolved { self?.mailRegistry.activate(identifier:String(identifier.dropFirst("makosh.mail.".count)),action:resolved) };return
            }
            guard action == UNNotificationDefaultActionIdentifier, identifier.hasPrefix(prefix) else { return }
            self?.registry.activate(identifier: String(identifier.dropFirst(prefix.count)))
        }
    }
}

// Source compatibility for existing Telegram hosts and boundary tests.
typealias TelegramSystemNotificationRouter = ApplicationSystemNotificationRouter
