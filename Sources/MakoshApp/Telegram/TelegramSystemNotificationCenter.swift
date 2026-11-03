import UserNotifications

@MainActor protocol ApplicationSystemNotificationCenter: AnyObject {
    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void)
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void)
    func add(_ request: UNNotificationRequest, withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?)
    func getDeliveredNotifications(completionHandler: @escaping @Sendable ([UNNotification]) -> Void)
    func getPendingNotificationRequests(completionHandler: @escaping @Sendable ([UNNotificationRequest]) -> Void)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: ApplicationSystemNotificationCenter {
    func getAuthorizationStatus(completionHandler: @escaping @Sendable (UNAuthorizationStatus) -> Void) {
        getNotificationSettings { completionHandler($0.authorizationStatus) }
    }
}

// Compatibility for the independently tested Telegram sink.
typealias TelegramSystemNotificationCenter = ApplicationSystemNotificationCenter
