import Foundation
import Combine
import MakoshMail

struct MailNotificationDelivery: Equatable, Identifiable {
    let event: MailNotificationEvent
    let rule: MailNotificationRule
    var id: String { event.id }
    var title: String { rule.previews ? (event.senderName.isEmpty ? event.sender : event.senderName) : "Почта" }
    var body: String { rule.previews ? event.subject : "Новое письмо" }
}

/// Presentation snapshots only; source admission, settings IO and checkpoints live in MakoshMail.
@MainActor final class MailNotificationController: ObservableObject {
    @Published private(set) var delivery: MailNotificationDelivery?
    @Published private(set) var revision = UUID()
    private(set) var preferences = MailNotificationPreferences()
    private var connected = Set<String>()
    private var statuses: [String:(MailMessageKey,Bool,Bool)] = [:]
    private var validity: [String:UInt32] = [:]
    private var deliveries: [String:MailNotificationDelivery] = [:]
    private var order:[String] = []
    private var active = false, locked = false
    private var restored = Set<String>()
    private(set) var hydrated = false
    func update(snapshot:MailSnapshot,connected:Set<String>,recoveryAccounts:Set<String>? = nil) {
        preferences = snapshot.notifications?.preferences ?? .init()
        self.connected = connected.intersection(Set(snapshot.accounts.map(\.id)))
        statuses = Dictionary(snapshot.letters.map { ($0.id,($0.key,$0.seen,$0.removedFromSource == true)) },uniquingKeysWith:{_,last in last})
        validity = Dictionary(snapshot.folders.compactMap { folder in folder.uidValidity.map { (folder.id,$0) } },uniquingKeysWith:{_,last in last})
        let recovery = recoveryAccounts ?? Set(snapshot.accounts.map(\.id))
        restored = []
        for (id, route) in snapshot.notifications?.routes ?? [:] {
            if route.consumed { deliveries.removeValue(forKey: id); continue }
            guard recovery.contains(route.event.key.accountID) else { continue }
            restored.insert(id)
            if deliveries[id] == nil { deliveries[id] = .init(event: route.event, rule: route.rule) }
        }
        hydrated = true
        invalidate()
    }
    func setPresentationEnvironment(active:Bool,locked:Bool) {
        guard self.active != active || self.locked != locked else { return }
        self.active=active;self.locked=locked;invalidate()
    }
    func receive(_ event: MailNotificationEvent) {
        guard !order.contains(event.id) else { return }
        let value = MailNotificationDelivery(event: event, rule: preferences.effective(for: event))
        deliveries[event.id] = value
        guard canPresent(identifier: event.id) else { deliveries.removeValue(forKey: event.id); return }
        order.append(event.id)
        if order.count > 100 { deliveries.removeValue(forKey: order.removeFirst()); revision = UUID() }
        delivery = value
    }
    func canPresent(identifier:String) -> Bool {
        canActivate(identifier: identifier) && deliveries[identifier].map { connected.contains($0.event.key.accountID) } == true && (!active || preferences.showWhileActive)
    }
    func canActivate(identifier:String) -> Bool {
        guard let delivery=deliveries[identifier], let status=statuses[identifier], status.0 == delivery.event.key,
              (connected.contains(delivery.event.key.accountID) || restored.contains(identifier)), !status.1, !status.2,
              validity[MailFolder(accountID:delivery.event.key.accountID,path:delivery.event.key.folder,kind:.inbox).id] == delivery.event.key.uidValidity,
              preferences.effective(for:delivery.event) == delivery.rule, delivery.rule.enabled,
              !locked else { return false }
        return true
    }
    func value(identifier:String) -> MailNotificationDelivery? { canActivate(identifier:identifier) ? deliveries[identifier] : nil }
    var activationIdentifiers: Set<String> { Set(deliveries.keys.filter { canActivate(identifier: $0) }) }
    private func invalidate() {
        for id in Array(deliveries.keys) where !canActivate(identifier:id) { deliveries.removeValue(forKey:id) }
        revision = UUID()
    }
}

@MainActor final class MailNotificationRegistry {
    private final class Entry {
        weak var controller:MailNotificationController?
        let activate:(MailNotificationAction,MailNotificationEvent)->Void
        init(_ controller:MailNotificationController,activate:@escaping(MailNotificationAction,MailNotificationEvent)->Void) { self.controller=controller;self.activate=activate }
    }
    private var entries:[UUID:Entry] = [:]
    private var routes:[String:UUID] = [:]
    private var consumed=Set<String>()
    private var pending: [String: MailNotificationAction] = [:]
    func register(_ controller:MailNotificationController,activate:@escaping(MailNotificationAction,MailNotificationEvent)->Void) -> UUID {
        let id=UUID();entries[id]=Entry(controller,activate:activate);return id
    }
    func unregister(_ id:UUID) { entries.removeValue(forKey:id);for key in routes.keys.filter({routes[$0]==id}) { routes.removeValue(forKey:key);consumed.remove(key) } }
    func admitDelivery(controller:MailNotificationController,identifier:String) -> Bool {
        for id in Array(routes.keys) where routes[id].flatMap({ entries[$0]?.controller })?.canActivate(identifier: id) != true { routes.removeValue(forKey: id); consumed.remove(id) }
        guard controller.canPresent(identifier:identifier),let owner=entries.first(where:{$0.value.controller === controller})?.key else{return false}
        if let previous=routes[identifier],previous != owner{return false}
        routes[identifier]=owner;return true
    }
    func canPresent(identifier:String) -> Bool { routes[identifier].flatMap{entries[$0]?.controller}?.canPresent(identifier:identifier) == true }
    func activate(identifier:String,action:MailNotificationAction) {
        guard !consumed.contains(identifier) else { return }
        guard let owner=routes[identifier],let entry=entries[owner],let value=entry.controller?.value(identifier:identifier) else {
            if routes[identifier] == nil, identifier.count == 64, identifier.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), pending.count < 100 { pending[identifier] = action }
            return
        }
        pending.removeValue(forKey: identifier)
        consumed.insert(identifier);entry.activate(action,value.event)
    }
    func restore(_ controller: MailNotificationController) {
        guard let owner = entries.first(where: { $0.value.controller === controller })?.key else { return }
        for id in controller.activationIdentifiers where routes[id] == nil || routes[id] == owner {
            routes[id] = owner
            if let action = pending[id] { activate(identifier: id, action: action) }
        }
    }
    var identifiers:Set<String> { Set(routes.keys.filter { routes[$0].flatMap { entries[$0]?.controller }?.canActivate(identifier: $0) == true }) }
}
