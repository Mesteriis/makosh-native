import MakoshMail
import SwiftUI

struct MailWorkspaceSettings: View {
    @ObservedObject var model: MailWorkspaceModel
    @State private var page = "Подписи, шаблоны и правила"
    var body: some View {
        VStack(spacing: 16) {
            WorkspaceSettingsTabs(titles: ["Подписи, шаблоны и правила", "Уведомления"], selection: $page)
            if page == "Уведомления" {
                MailNotificationSettingsView(model: model, scope: .global, embedded: true)
            } else {
                MailAutomationSettingsView(model: model, embedded: true)
            }
        }
    }
}
