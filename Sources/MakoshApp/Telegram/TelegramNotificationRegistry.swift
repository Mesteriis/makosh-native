import Foundation
import Combine
import MakoshTelegram

/// App-owned routing; a second workspace must not replace the first one's routes.
@MainActor final class TelegramNotificationRegistry: ObservableObject {
    private struct Entry {
        weak var controller: TelegramNotificationController?
        let activateWindow: () -> Void
        var count: Int
        var observation: AnyCancellable?
    }
    private var entries: [UUID: Entry] = [:]
    private var seen = Set<String>(), seenOrder: [String] = []
    @Published private(set) var badgeCount = 0
    func register(_ controller: TelegramNotificationController, activateWindow: @escaping () -> Void) -> UUID {
        entries = entries.filter { $0.value.controller != nil }
        let id = UUID(); entries[id] = .init(controller: controller, activateWindow: activateWindow, count: controller.badgeCount)
        let observation = controller.$badgeCount.sink { [weak self] count in
            guard let self, self.entries[id] != nil else { return }
            self.entries[id]?.count = count; self.updateBadge()
        }
        entries[id]?.observation = observation
        updateBadge(); return id
    }
    func unregister(_ registration: UUID) { entries.removeValue(forKey: registration); updateBadge() }
    func admitDelivery(controller: TelegramNotificationController, identity: String) -> Bool {
        guard controller.accountID != nil, entries.values.contains(where: { $0.controller === controller }),
              !identity.isEmpty, identity.utf8.count <= 256, !seen.contains(identity) else { return false }
        seen.insert(identity); seenOrder.append(identity)
        if seenOrder.count > 4096 { seen.remove(seenOrder.removeFirst()) }
        return true
    }
    private func owner(_ identifier: String) -> Entry? {
        entries.values.first { $0.controller?.notificationIdentifiers.contains(identifier) == true }
    }
    func canPresent(identifier: String) -> Bool { owner(identifier)?.controller?.canPresent(identifier: identifier) == true }
    func activate(identifier: String) -> Bool {
        guard let entry = owner(identifier), entry.controller?.activate(identifier: identifier) == true else { return false }
        entry.activateWindow(); return true
    }
    var identifiers: Set<String> { Set(entries.values.flatMap { $0.controller?.notificationIdentifiers ?? [] }) }
    private func updateBadge() {
        var accounts: [Int64: Int] = [:]
        for entry in entries.values {
            if let controller = entry.controller, let account = controller.accountID {
                accounts[account] = max(accounts[account] ?? 0, entry.count)
            }
        }
        badgeCount = accounts.values.reduce(0) { min(999_999, $0 + $1) }
    }
}
