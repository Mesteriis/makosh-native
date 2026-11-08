import AppKit
import MakoshCalendar
import UserNotifications

/// Calendar reminders through the application's one notification delegate.
/// Identifiers are opaque (`makosh.calendar.<event>.<start>.<minutes>`); a reminder
/// is shown only while its event still plans it.
@MainActor final class CalendarSystemNotifications {
    nonisolated static let prefix = "makosh.calendar."
    private(set) var identifiers = Set<String>()
    var open: ((UUID) -> Void)?
    private weak var router: ApplicationSystemNotificationRouter?
    private let systemEnabled: Bool

    init(router: ApplicationSystemNotificationRouter?, systemEnabled: Bool) {
        self.router = router
        self.systemEnabled = systemEnabled
    }

    /// Replaces scheduled reminders with `planned`: stale ones are removed, new ones added.
    func reschedule(_ planned: Set<CalendarReminder>, now: Date) async {
        identifiers = Set(planned.map(\.identifier))
        guard systemEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined, !planned.isEmpty, let router, !router.authorizationAttempted,
            router.beginAuthorizationRequest()
        {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            router.finishAuthorizationRequest()
        }
        let pending = Set(await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) })
        let wanted = Set(planned.map { Self.prefix + $0.identifier })
        center.removePendingNotificationRequests(withIdentifiers: Array(pending.subtracting(wanted)))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "HH:mm"
        for reminder in planned where !pending.contains(Self.prefix + reminder.identifier) {
            let content = UNMutableNotificationContent()
            content.title = reminder.title.isEmpty ? "Событие" : reminder.title
            content.body = "Начало в " + formatter.string(from: reminder.start)
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.fireAt.timeIntervalSince(now)), repeats: false)
            try? await center.add(UNNotificationRequest(identifier: Self.prefix + reminder.identifier, content: content, trigger: trigger))
        }
    }

    func canPresent(_ identifier: String) -> Bool { identifiers.contains(identifier) }

    func activate(_ identifier: String) {
        guard let eventID = CalendarReminderPlanner.eventID(fromIdentifier: identifier) else { return }
        NSApp.activate(ignoringOtherApps: true)
        open?(eventID)
    }
}
