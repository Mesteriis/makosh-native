import AppKit
import Combine
import MakoshTeams
import SwiftUI
import UserNotifications

@MainActor final class TeamsNotificationRegistry {
  private final class Entry {
    weak var system: TeamsSystemNotifications?
    init(_ system: TeamsSystemNotifications) { self.system = system }
  }
  private var entries: [UUID: Entry] = [:]
  private var pending = Set<String>()
  func register(_ system: TeamsSystemNotifications) -> UUID {
    let id = UUID()
    entries[id] = Entry(system)
    return id
  }
  func unregister(_ id: UUID) { entries.removeValue(forKey: id) }
  var identifiers: Set<String> {
    Set(entries.values.compactMap(\.system).flatMap { Array($0.identifiers) })
  }
  func canPresent(_ id: String) async -> Bool {
    for system in entries.values.compactMap(\.system) {
      if await system.canPresent(id) { return true }
    }
    return false
  }
  func activate(_ id: String) async {
    guard TeamsRepository.validNotificationToken(id)
    else { return }
    for system in entries.values.compactMap(\.system) {
      if await system.activate(id) {
        pending.remove(id)
        return
      }
    }
    if pending.count < 100 { pending.insert(id) }
  }
  func restore() async { for id in pending { await activate(id) } }
  func revalidate() async { for system in entries.values.compactMap(\.system) { await system.revalidate() } }
}

@MainActor final class TeamsSystemNotifications: ObservableObject {
  @Published private(set) var status: String?
  weak var window: NSWindow? { didSet { if oldValue !== window { observeWindow() } } }
  private let windowState: (@MainActor () -> ApplicationNotificationWindowState)?
  private var windowObservers: [NSObjectProtocol] = []
  private let worker: any TeamsNotificationServing
  private let center: any ApplicationSystemNotificationCenter
  private let activation: (TeamsNotificationEvent) -> Void
  private weak var router: ApplicationSystemNotificationRouter?
  private var registration: UUID?
  private var routes: [String: TeamsNotificationEvent] = [:]
  private var submitted: [String: Int64] = [:]
  private var policies: [String: TeamsNotificationRule] = [:]
  private var locked = false
  private var observers: [NSObjectProtocol] = []
  var identifiers: Set<String> { Set(routes.keys) }
  init(
    worker: any TeamsNotificationServing,
    center: any ApplicationSystemNotificationCenter = UNUserNotificationCenter.current(),
    windowState: (@MainActor () -> ApplicationNotificationWindowState)? = nil,
    activation: @escaping (TeamsNotificationEvent) -> Void = { _ in }
  ) {
    self.worker = worker
    self.windowState = windowState
    self.center = center
    self.activation = activation
    for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
      observers.append(
        DistributedNotificationCenter.default().addObserver(
          forName: .init(name), object: nil, queue: .main
        ) { [weak self] event in
          let isLocked = event.name.rawValue == "com.apple.screenIsLocked"
          MainActor.assumeIsolated {
            guard let self else { return }
            self.locked = isLocked
            if self.locked { self.clearAll() }
          }
        })
    }
  }
  isolated deinit {
    clearAll()
    if let registration { router?.teamsRegistry.unregister(registration) }
    for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
    for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
  }
  func attach(_ router: ApplicationSystemNotificationRouter) {
    guard registration == nil else { return }
    self.router = router
    registration = router.teamsRegistry.register(self)
  }
  private func eligible(_ event: TeamsNotificationEvent) async -> TeamsNotificationRule? {
    guard !locked, event.timestamp >= Int64(Date().timeIntervalSince1970) - 120,
      event.timestamp <= Int64(Date().timeIntervalSince1970) + 60
    else { return nil }
    do {
      guard try await worker.notificationIsCurrent(event) else { return nil }
      let rule = try await worker.notificationRule(conversation: event.scope)
      guard try await worker.notificationIsCurrent(event), try await worker.notificationRule(conversation: event.scope) == rule else { return nil }
      let active = applicationNotificationWindowIsActive(windowState?() ??
        .init(
          applicationActive: NSApp?.isActive ?? false, hasWindow: window != nil,
          key: window?.isKeyWindow ?? false, visible: window?.isVisible ?? false,
          miniaturized: window?.isMiniaturized ?? false))
      guard !locked, rule.show, rule.foreground || !active else { return nil }
      return rule
    } catch { return nil }
  }
  private func observeWindow() {
    for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    windowObservers.removeAll()
    let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
    for name in names {
      windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in await self?.revalidate() }
      })
    }
  }
  func canPresent(_ id: String) async -> Bool {
    guard let event = routes[id] else { return false }
    guard let rule = await eligible(event), rule == policies[id] else {
      clear(id)
      return false
    }
    return true
  }
  func deliver(_ event: TeamsNotificationEvent) async {
    guard submitted[event.id] == nil, await eligible(event) != nil else { return }
    var authorization = await permission()
    if authorization == .notDetermined {
      if router?.authorizationRequesting == true {
        for _ in 0..<200 {
          try? await Task.sleep(for: .milliseconds(50))
          if router?.authorizationRequesting != true { break }
        }
        authorization = await permission()
      }
      if authorization == .notDetermined, router?.authorizationAttempted != true {
        guard let router, router.beginAuthorizationRequest() else { return }
        let granted: Bool = await withCheckedContinuation { continuation in
          center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            continuation.resume(returning: granted && error == nil)
          }
        }
        router.finishAuthorizationRequest()
        authorization = granted ? .authorized : .denied
      }
    }
    guard authorization == .authorized || authorization == .provisional,
      let rule = await eligible(event)
    else {
      status = "Уведомления выключены или ограничены текущими настройками."
      return
    }
    submitted = submitted.filter { $0.value >= Int64(Date().timeIntervalSince1970) - 120 }
    submitted[event.id] = event.timestamp
    routes[event.id] = event
    policies[event.id] = rule
    if submitted.count > 1000, let oldest = submitted.min(by: { $0.value < $1.value })?.key {
      submitted.removeValue(forKey: oldest)
    }
    if routes.count > 100, let oldest = routes.values.min(by: { $0.timestamp < $1.timestamp }) {
      clear(oldest.id)
    }
    let content = UNMutableNotificationContent()
    content.title = rule.preview ? event.title : "Microsoft Teams"
    content.body = rule.preview ? event.body : "Новое сообщение"
    content.sound = rule.sound ? .default : nil
    content.threadIdentifier = event.thread
    content.userInfo = ["makosh.teams.token": event.id]
    let request = UNNotificationRequest(
      identifier: "makosh.teams." + event.id, content: content, trigger: nil)
    let success: Bool = await withCheckedContinuation { continuation in
      center.add(request) { error in continuation.resume(returning: error == nil) }
    }
    let stillEligible = await eligible(event) == rule
    if !success || !stillEligible { clear(event.id) }
    if !success {
      status = "macOS не приняла уведомление. Повторная отправка автоматически не выполняется."
    }
  }
  func revalidate() async {
    for (id, event) in routes {
      let rule = await eligible(event)
      if rule == nil || rule != policies[id] { clear(id) }
    }
  }
  func requestPermission() async {
    guard router?.beginAuthorizationRequest() != false else { return }
    let granted: Bool = await withCheckedContinuation { continuation in
      center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
        continuation.resume(returning: granted && error == nil)
      }
    }
    router?.finishAuthorizationRequest()
    status = granted ? "Уведомления разрешены" : "Разрешите уведомления в настройках macOS"
  }
  private func permission() async -> UNAuthorizationStatus {
    await withCheckedContinuation { continuation in
      center.getAuthorizationStatus { continuation.resume(returning: $0) }
    }
  }
  func activate(_ id: String) async -> Bool {
    guard !locked else { return false }
    do {
      guard let event = try await worker.activateNotification(token: id), !locked else {
        return false
      }
      NSApp?.activate(ignoringOtherApps: true)
      window?.makeKeyAndOrderFront(nil)
      activation(event)
      clear(id)
      return true
    } catch { return false }
  }
  private func clear(_ id: String) {
    routes.removeValue(forKey: id)
    policies.removeValue(forKey: id)
    center.removePendingNotificationRequests(withIdentifiers: ["makosh.teams." + id])
    center.removeDeliveredNotifications(withIdentifiers: ["makosh.teams." + id])
  }
  private func clearAll() { for id in Array(routes.keys) { clear(id) } }
}

struct TeamsNotificationHost: ViewModifier {
    @EnvironmentObject private var router: ApplicationSystemNotificationRouter
    @ObservedObject var model: TeamsWorkspaceModel
    @StateObject private var system: TeamsSystemNotifications
    init(model: TeamsWorkspaceModel) {
        self.model = model
        let center: any ApplicationSystemNotificationCenter = model.isSynthetic ? TeamsSyntheticNotificationCenter() : UNUserNotificationCenter.current()
        _system = StateObject(wrappedValue: TeamsSystemNotifications(worker: model.notificationWorker, center: center, activation: { [weak model] event in Task { await model?.openNotification(event) } }))
    }
    func body(content: Content) -> some View {
        content.background(TeamsNotificationWindow(system: system).frame(width: 0, height: 0))
            .onAppear { system.attach(router) }
            .onReceive(model.$notificationEvents) { events in Task { for event in events { await system.deliver(event) } } }
            .onReceive(model.$snapshot) { _ in Task { await system.revalidate() } }
            .onReceive(model.$accounts) { _ in Task { await router.teamsRegistry.restore() } }
    }
}
private struct TeamsNotificationWindow: NSViewRepresentable {
    let system: TeamsSystemNotifications
    final class Probe: NSView { weak var system: TeamsSystemNotifications?; override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); system?.window = window } }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.system = system; return view }
    func updateNSView(_ view: Probe, context: Context) { view.system = system; system.window = view.window }
}
