import AppKit
import Combine
import SwiftUI
import UserNotifications
import MakoshMail
import OSLog

func mailSystemNotificationContent(_ delivery: MailNotificationDelivery) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = delivery.title
    content.body = delivery.body
    content.sound = delivery.rule.sound ? .default : nil
    content.categoryIdentifier = ApplicationSystemNotificationRouter.mailCategory
    content.threadIdentifier = MailNotificationScope.sender(accountID: delivery.event.key.accountID, address: delivery.event.sender).id
    content.userInfo = ["makosh.mail.token": delivery.id]
    return content
}

struct MailNotificationHost: ViewModifier {
    @EnvironmentObject private var router: ApplicationSystemNotificationRouter
    @StateObject private var system: MailSystemNotifications
    init(model: MailWorkspaceModel) {
        _system = StateObject(wrappedValue: MailSystemNotifications(controller: model.notifications, activate: { [weak model] action, event in
            Task { await model?.handleNotificationAction(action, event: event) }
        }))
    }
    func body(content: Content) -> some View {
        content.environmentObject(system)
            .background(MailNotificationWindowProbe(system: system).frame(width: 0, height: 0))
            .onAppear { system.attach(router) }
    }
}

private struct MailNotificationWindowProbe: NSViewRepresentable {
    let system: MailSystemNotifications
    final class Probe: NSView {
        weak var system: MailSystemNotifications?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); system?.window = window }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.system = system; return view }
    func updateNSView(_ view: Probe, context: Context) { view.system = system; system.window = view.window }
}

func mailNotificationIDsToClear(_ observed: [String], keeping current: Set<String>) -> [String] {
    observed.filter { $0.hasPrefix("makosh.mail.") && !current.contains($0) }
}

@MainActor final class MailSystemNotifications: NSObject, ObservableObject {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "org.makosh.desktop", category: "MailNotifications")
    @Published private(set) var authorization = UNAuthorizationStatus.notDetermined
    @Published private(set) var status: String?
    @Published private(set) var requesting = false
    private let controller: MailNotificationController
    private let center: any ApplicationSystemNotificationCenter
    private let windowState: (@MainActor () -> ApplicationNotificationWindowState)?
    private let activate: (MailNotificationAction, MailNotificationEvent) -> Void
    private weak var router: ApplicationSystemNotificationRouter?
    private var registration: UUID?
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var screenLocked = false
    private var authorizationRevision = UUID()
    private var submitted = Set<String>(), submittedOrder: [String] = []
    private var pending: [MailNotificationDelivery] = []
    private var checkingAuthorization = false, attemptedAuthorization = false
    private static let prefix = "makosh.mail."
    weak var window: NSWindow? {
        didSet {
            guard oldValue !== window else { return }
            observeWindow()
            updateEnvironment()
        }
    }

    init(controller: MailNotificationController,
         center: any ApplicationSystemNotificationCenter = UNUserNotificationCenter.current(),
         windowState: (@MainActor () -> ApplicationNotificationWindowState)? = nil,
         activate: @escaping (MailNotificationAction, MailNotificationEvent) -> Void = { _, _ in }) {
        self.controller = controller; self.center = center
        self.windowState = windowState; self.activate = activate
        super.init()
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEnvironment(); self?.refreshAuthorization() }
            })
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] event in
                let locked = event.name.rawValue == "com.apple.screenIsLocked"
                MainActor.assumeIsolated {
                    self?.screenLocked = locked
                    self?.updateEnvironment()
                }
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
        if let registration { router?.mailRegistry.unregister(registration) }
        // Delivered routes are encrypted and restored by the next process.
    }
    func attach(_ router: ApplicationSystemNotificationRouter) {
        guard registration == nil else { return }
        self.router = router
        registration = router.mailRegistry.register(controller) { [weak self] action, event in
            guard let self else { return }
            NSApp?.activate(ignoringOtherApps: true)
            self.window?.makeKeyAndOrderFront(nil)
            self.activate(action, event)
        }
        controller.$revision.sink { [weak self] _ in
            guard let self else { return }; self.router?.mailRegistry.restore(self.controller); self.clearInvalid()
        }.store(in: &subscriptions)
        controller.$delivery.compactMap { $0 }.sink { [weak self] in self?.deliver($0) }.store(in: &subscriptions)
        router.$authorizationRequesting.dropFirst().sink { [weak self] inProgress in
            if !inProgress { self?.checkPendingAuthorization() }
        }.store(in: &subscriptions)
        router.mailRegistry.restore(controller)
    }
    private func updateEnvironment() {
        let state = windowState?() ?? .init(applicationActive: NSApp?.isActive ?? false, hasWindow: window != nil,
            key: window?.isKeyWindow ?? false, visible: window?.isVisible ?? false, miniaturized: window?.isMiniaturized ?? false)
        controller.setPresentationEnvironment(active: applicationNotificationWindowIsActive(state), locked: screenLocked)
    }
    private func observeWindow() {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didUpdateNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateEnvironment() }
            })
        }
    }
    func refreshAuthorization() {
        let token = UUID(); authorizationRevision = token
        center.getAuthorizationStatus { [weak self] status in
            Task { @MainActor in
                guard let self, self.authorizationRevision == token else { return }
                self.authorization = status
                Self.logger.debug("System notification authorization status: \(status.rawValue, privacy: .public)")
            }
        }
    }
    func requestAuthorization() {
        guard !requesting else { return }
        guard router?.beginAuthorizationRequest() != false else { return }
        attemptedAuthorization = true; router?.authorizationAttempted = true
        requesting = true; status = nil; authorizationRevision = UUID()
        Self.logger.info("Requesting system notification permission")
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self, weak router = router] granted, error in
            let failed = error != nil
            Task { @MainActor in
                router?.finishAuthorizationRequest()
                guard let self else { return }
                self.requesting = false
                Self.logger.info("System notification permission completed: granted=\(granted, privacy: .public), failed=\(failed, privacy: .public)")
                self.status = failed ? "macOS не завершила запрос разрешения." : granted ? "Системные уведомления разрешены." : "Уведомления выключены в настройках macOS."
                if failed || !granted { self.pending = [] }
                self.refreshAuthorization()
                if !failed && granted { self.checkPendingAuthorization() }
            }
        }
    }
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private func deliver(_ delivery: MailNotificationDelivery) {
        updateEnvironment()
        guard controller.canPresent(identifier: delivery.id), router?.mailRegistry.admitDelivery(controller: controller, identifier: delivery.id) == true else {
            Self.logger.debug("Incoming notification suppressed by current policy or route ownership")
            return
        }
        guard !submitted.contains(Self.prefix + delivery.id), !pending.contains(where: { $0.id == delivery.id }) else { return }
        pending.append(delivery)
        if pending.count > 100 { pending.removeFirst() }
        checkPendingAuthorization()
    }
    private func checkPendingAuthorization() {
        guard !pending.isEmpty, !checkingAuthorization, !requesting else { return }
        checkingAuthorization = true
        center.getAuthorizationStatus { [weak self] authorization in
            Task { @MainActor in
                guard let self else { return }
                self.checkingAuthorization = false; self.authorization = authorization
                self.updateEnvironment()
                self.pending.removeAll { !self.controller.canPresent(identifier: $0.id) }
                guard !self.pending.isEmpty else { return }
                Self.logger.debug("Checking eligible notification delivery; authorization status: \(authorization.rawValue, privacy: .public)")
                switch authorization {
                case .authorized, .provisional:
                    let deliveries = self.pending; self.pending = []
                    for delivery in deliveries { self.submit(delivery) }
                case .notDetermined:
                    if self.router?.authorizationRequesting == true { break }
                    else if self.attemptedAuthorization || self.router?.authorizationAttempted == true { self.pending = [] }
                    else { self.requestAuthorization() }
                default:
                    self.pending = []; self.status = "Уведомления выключены в настройках macOS."
                }
            }
        }
    }
    private func submit(_ delivery: MailNotificationDelivery) {
        updateEnvironment()
        guard controller.canPresent(identifier: delivery.id) else { return }
        let identifier = Self.prefix + delivery.id
        guard submitted.insert(identifier).inserted else { return }
        submittedOrder.append(identifier)
        if submittedOrder.count > 100 {
            let old = submittedOrder.removeFirst(); submitted.remove(old)
            remove([old])
        }
        center.add(.init(identifier: identifier, content: mailSystemNotificationContent(delivery), trigger: nil)) { [weak self] error in
            let failed = error != nil
            Task { @MainActor in
                guard let self else { return }
                self.updateEnvironment()
                guard self.controller.canPresent(identifier: delivery.id) else { self.remove([identifier]); return }
                if failed {
                    Self.logger.error("macOS rejected a notification request")
                    self.status = "macOS не приняла уведомление. Проверьте системные разрешения."
                } else {
                    // Acceptance by the API is separate from an observed OS banner.
                    Self.logger.debug("macOS accepted a notification request")
                }
            }
        }
    }
    private func remove(_ ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }
    private func clearInvalid() {
        pending.removeAll { !controller.canPresent(identifier: $0.id) }
        let invalid = submitted.filter { !controller.canActivate(identifier: String($0.dropFirst(Self.prefix.count))) }
        submitted.subtract(invalid); submittedOrder.removeAll { invalid.contains($0) }
        remove(Array(invalid))
        if controller.hydrated { clearStaleSystemCards() }
    }
    private func clearStaleSystemCards() {
        center.getDeliveredNotifications { [weak self] cards in
            let ids = cards.map { $0.request.identifier }
            Task { @MainActor in
                guard let self else { return }
                self.center.removeDeliveredNotifications(withIdentifiers: mailNotificationIDsToClear(ids, keeping: self.router?.systemIdentifiers ?? []))
            }
        }
        center.getPendingNotificationRequests { [weak self] cards in
            let ids = cards.map(\.identifier)
            Task { @MainActor in
                guard let self else { return }
                self.center.removePendingNotificationRequests(withIdentifiers: mailNotificationIDsToClear(ids, keeping: self.router?.systemIdentifiers ?? []))
            }
        }
    }
}
