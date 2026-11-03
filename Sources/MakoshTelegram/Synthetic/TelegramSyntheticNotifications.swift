#if DEBUG
import Foundation

extension TelegramNotificationController {
    public func sendSyntheticNotification() {
        guard accountID == -1 else { return }
        receive(.init(accountID: -1, peerID: 10001, namespace: 0, messageID: Int32.random(in: 1...Int32.max),
            threadID: nil, timestamp: Int32(Date().timeIntervalSince1970), category: .personal,
            title: "Синтетический чат", text: try? .init(text: "Проверка уведомлений"), fallback: "Новое сообщение",
            incoming: true, serverNotify: true, serverPreviews: true, serverSilent: false,
            secret: false, protected: false, serviceCodes: false), contextID: contextID)
    }
}
#endif
