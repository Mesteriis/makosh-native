import AppKit
import UserNotifications
import Combine
import MakoshTelegram
import SwiftUI

func telegramSystemNotificationContent(_ delivery: TelegramNotificationDelivery) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = delivery.title; content.body = delivery.body
    content.sound = delivery.sound ? .default : nil
    content.userInfo = ["makosh.telegram.token": delivery.id]
    return content
}

func telegramNotificationIDsToClear(_ observed: [String], keeping current: Set<String>) -> [String] {
    observed.filter { $0.hasPrefix("makosh.telegram.") && !current.contains($0) }
}

struct ApplicationNotificationWindowState: Sendable {
    var applicationActive: Bool
    var hasWindow: Bool
    var key: Bool
    var visible: Bool
    var miniaturized: Bool
}

func applicationNotificationWindowIsActive(_ state: ApplicationNotificationWindowState) -> Bool {
    state.applicationActive && state.hasWindow && state.key && state.visible && !state.miniaturized
}

typealias TelegramNotificationWindowState = ApplicationNotificationWindowState
func telegramNotificationWindowIsActive(_ state:TelegramNotificationWindowState) -> Bool { applicationNotificationWindowIsActive(state) }

@MainActor final class TelegramSystemNotifications: NSObject, ObservableObject {
    @Published private(set) var authorization = UNAuthorizationStatus.notDetermined
    @Published private(set) var status: String?
    @Published private(set) var requesting = false
    #if DEBUG
    @Published private(set) var syntheticSystemDelivery: String?
    func verifySyntheticDelivery() {
        guard controller.accountID == -1, let delivery = controller.delivery else { return }
        let token = revision, id = Self.prefix + delivery.id
        center.getDeliveredNotifications { [weak self] notifications in
            let delivered = notifications.first { $0.request.identifier == id }
            let exact = delivered?.request.content.title == delivery.title && delivered?.request.content.body == delivery.body
            Task { @MainActor in
                guard let self, self.revision == token, self.controller.accountID == -1 else { return }
                self.syntheticSystemDelivery = exact ? "macOS: карточка доставлена · \(delivery.body)" : "macOS: карточка ещё не найдена среди доставленных."
            }
        }
    }
    #endif
    private let controller: TelegramNotificationController
    private weak var router: TelegramSystemNotificationRouter?
    private var registration: UUID?
    weak var window: NSWindow? {
        didSet {
            guard oldValue !== window else { return }
            observeWindow(); updateEnvironment()
        }
    }
    private let center: any TelegramSystemNotificationCenter
    private let windowState: (@MainActor () -> TelegramNotificationWindowState)?
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var screenLocked = false
    private var revision = UUID(), authorizationRevision = UUID()
    private var submitted = Set<String>(), submittedOrder: [String] = []
    private var pendingDeliveries: [TelegramNotificationDelivery] = []
    private var checkingAuthorization = false
    private var attemptedAuthorization = false
    private static let prefix = "makosh.telegram."
    init(controller: TelegramNotificationController, center: any TelegramSystemNotificationCenter = UNUserNotificationCenter.current(),
         windowState: (@MainActor () -> TelegramNotificationWindowState)? = nil) {
        self.controller = controller
        self.center = center
        self.windowState = windowState
        super.init()
        let notifications = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEnvironment(); self?.refreshAuthorization() }
            })
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] event in
                let locked = event.name.rawValue == "com.apple.screenIsLocked"
                MainActor.assumeIsolated { self?.screenLocked = locked; self?.updateEnvironment() }
            })
        }
        updateEnvironment(); refreshAuthorization()
    }
    isolated deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let registration { router?.registry.unregister(registration) }
        center.removePendingNotificationRequests(withIdentifiers: Array(submitted))
        center.removeDeliveredNotifications(withIdentifiers: Array(submitted))
    }
    func attach(_ router: TelegramSystemNotificationRouter) {
        updateEnvironment()
        guard registration == nil else { return }
        self.router = router
        registration = router.registry.register(controller) { [weak self] in
            NSApp.activate(ignoringOtherApps: true); self?.window?.makeKeyAndOrderFront(nil)
        }
        router.$authorizationRequesting.dropFirst().sink { [weak self] inProgress in
            if !inProgress { self?.checkPendingAuthorization() }
        }.store(in: &subscriptions)
        controller.$clearRequest.sink { [weak self] _ in self?.clear() }.store(in: &subscriptions)
        controller.$delivery.compactMap { $0 }.sink { [weak self] in self?.deliver($0) }.store(in: &subscriptions)
    }
    private func updateEnvironment() {
        let state = windowState?() ?? .init(applicationActive: NSApp?.isActive ?? false, hasWindow: window != nil,
            key: window?.isKeyWindow ?? false, visible: window?.isVisible ?? false, miniaturized: window?.isMiniaturized ?? false)
        controller.setPresentationEnvironment(active: telegramNotificationWindowIsActive(state), locked: screenLocked)
    }
    private func observeWindow() {
        let notifications = NotificationCenter.default
        for observer in windowObservers { notifications.removeObserver(observer) }
        windowObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didUpdateNotification] {
            windowObservers.append(notifications.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEnvironment() }
            })
        }
    }
    func refreshAuthorization() {
        let token = UUID(); authorizationRevision = token
        center.getAuthorizationStatus { [weak self] status in
            let raw = status.rawValue
            Task { @MainActor in
                guard let self, self.authorizationRevision == token, let value = UNAuthorizationStatus(rawValue: raw) else { return }
                self.authorization = value
            }
        }
    }
    func requestAuthorization() {
        guard !requesting else { return }
        guard router?.beginAuthorizationRequest() != false else { return }
        attemptedAuthorization = true
        router?.authorizationAttempted = true
        requesting = true; status = nil
        authorizationRevision = UUID()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self, weak router = router] granted, error in
            let failed = error != nil
            Task { @MainActor in
                router?.finishAuthorizationRequest()
                guard let self else { return }
                self.requesting = false
                self.status = failed ? "macOS не завершила запрос разрешения." : granted ? "Системные уведомления разрешены." : "Уведомления выключены в настройках macOS."
                if failed || !granted { self.pendingDeliveries = [] }
                self.refreshAuthorization()
                if !failed && granted { self.checkPendingAuthorization() }
            }
        }
    }
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private func deliver(_ delivery: TelegramNotificationDelivery) {
        updateEnvironment()
        guard controller.canPresent(identifier: delivery.id), let sourceKey = delivery.sourceKey,
              router?.registry.admitDelivery(controller: controller, identity: sourceKey) == true else { return }
        pendingDeliveries.append(delivery)
        if pendingDeliveries.count > 100 { pendingDeliveries.removeFirst() }
        checkPendingAuthorization()
    }
    private func checkPendingAuthorization() {
        guard !pendingDeliveries.isEmpty, !checkingAuthorization, !requesting else { return }
        checkingAuthorization = true
        let token = revision
        center.getAuthorizationStatus { [weak self] authorization in
            Task { @MainActor in
                guard let self, self.revision == token else { return }
                self.checkingAuthorization = false
                self.authorization = authorization
                // Account, privacy and presentation state may change while macOS is responding.
                self.updateEnvironment()
                self.pendingDeliveries.removeAll { !self.controller.canPresent(identifier: $0.id) }
                guard !self.pendingDeliveries.isEmpty else { return }
                switch authorization {
                case .authorized, .provisional:
                    let deliveries = self.pendingDeliveries; self.pendingDeliveries = []
                    for delivery in deliveries { self.submit(delivery) }
                case .notDetermined:
                    if self.router?.authorizationRequesting == true { break }
                    else if self.attemptedAuthorization || self.router?.authorizationAttempted == true {
                        self.pendingDeliveries = []
                    } else {
                        self.requestAuthorization()
                    }
                default:
                    self.pendingDeliveries = []
                    self.status = "Уведомления выключены в настройках macOS."
                }
            }
        }
    }
    private func submit(_ delivery: TelegramNotificationDelivery) {
        updateEnvironment()
        guard controller.canPresent(identifier: delivery.id) else { return }
        let identifier = Self.prefix + delivery.id, token = revision
        submitted.insert(identifier); submittedOrder.append(identifier)
        if submittedOrder.count > 100 {
            let oldest = submittedOrder.removeFirst(); submitted.remove(oldest)
            center.removePendingNotificationRequests(withIdentifiers: [oldest])
            center.removeDeliveredNotifications(withIdentifiers: [oldest])
        }
        let request = UNNotificationRequest(identifier: identifier, content: telegramSystemNotificationContent(delivery), trigger: nil)
        center.add(request) { [weak self] error in
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                self.updateEnvironment()
                guard self.revision == token, self.controller.canPresent(identifier: delivery.id) else {
                    self.center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    self.center.removeDeliveredNotifications(withIdentifiers: [identifier]); return
                }
                if failed { self.status = "macOS не приняла уведомление. Проверьте системные разрешения." }
                else if delivery.bounce && NSApp?.isActive == false { NSApp?.requestUserAttention(.informationalRequest) }
            }
        }
    }
    private func clear() {
        revision = UUID()
        pendingDeliveries = []; checkingAuthorization = false
        let old = Array(submitted); submitted = []; submittedOrder = []
        center.removePendingNotificationRequests(withIdentifiers: old)
        center.removeDeliveredNotifications(withIdentifiers: old)
        center.getDeliveredNotifications { [weak self] notifications in
            let ids = notifications.map { $0.request.identifier }
            Task { @MainActor in
                guard let self else { return }
                self.center.removeDeliveredNotifications(withIdentifiers: telegramNotificationIDsToClear(ids, keeping: self.router?.systemIdentifiers ?? self.submitted))
            }
        }
        center.getPendingNotificationRequests { [weak self] requests in
            let ids = requests.map(\.identifier)
            Task { @MainActor in
                guard let self else { return }
                self.center.removePendingNotificationRequests(withIdentifiers: telegramNotificationIDsToClear(ids, keeping: self.router?.systemIdentifiers ?? self.submitted))
            }
        }
    }
}

struct TelegramNotificationHost: ViewModifier {
    @EnvironmentObject private var router: TelegramSystemNotificationRouter
    @StateObject private var system: TelegramSystemNotifications
    init(controller: TelegramNotificationController) { _system = StateObject(wrappedValue: TelegramSystemNotifications(controller: controller)) }
    func body(content: Content) -> some View {
        content.environmentObject(system).background(TelegramNotificationWindowProbe(system: system).frame(width: 0, height: 0))
            .onAppear { system.attach(router) }
    }
}

private struct TelegramNotificationWindowProbe: NSViewRepresentable {
    let system: TelegramSystemNotifications
    final class Probe: NSView {
        weak var system: TelegramSystemNotifications?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); system?.window = window }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.system = system; return view }
    func updateNSView(_ view: Probe, context: Context) { view.system = system; system.window = view.window }
}
