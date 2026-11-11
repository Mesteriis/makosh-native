import MakoshMail
import SwiftUI

struct MailWorkspaceSettings: View {
    @ObservedObject var model: MailWorkspaceModel
    @State private var page = "Подпись"
    @State private var draft = MailAutomationDraft()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceSettingsTabs(titles: ["Подпись", "Шаблоны", "Правила", "Уведомления"], selection: $page)
            if page == "Уведомления" {
                MailNotificationSettingsView(model: model, scope: .global, embedded: true)
            } else {
                MailAutomationSettingsView(
                    model: model, embedded: true, page: ["Подпись", "Шаблоны", "Правила"].firstIndex(of: page) ?? 0, draft: $draft)
            }
        }
    }
}
