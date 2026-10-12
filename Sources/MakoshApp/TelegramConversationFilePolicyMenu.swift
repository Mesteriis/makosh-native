import SwiftUI
import MakoshTelegram

struct TelegramConversationFilePolicyMenu: View {
    @ObservedObject private var policy: TelegramConversationFilePolicyController
    let chatID: Int64
    init(files: TelegramFileArchiveController, chatID: Int64) {
        policy = files.policy; self.chatID = chatID
    }
    var body: some View {
        Menu {
            if let context = policy.context, context.chatID == chatID {
                Toggle("Сохранять файлы в S3", isOn: Binding(get: { policy.enabled ?? false }, set: { enabled in
                    Task { await policy.setEnabled(enabled, contextID: context.id) }
                }))
                .disabled(policy.isBusy || policy.enabled == nil)
                .accessibilityIdentifier("telegram.chat.saveFilesS3")
                if policy.isBusy { Text("Загрузка или сохранение настройки…") }
                if let error = policy.error {
                    Text(error)
                    Button("Повторить загрузку настройки") { policy.reload(contextID: context.id) }
                        .accessibilityIdentifier("telegram.chat.saveFilesS3.retry")
                }
            }
        } label: {
            Image(systemName: policy.enabled == true ? "externaldrive.badge.checkmark" : "externaldrive")
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Сохранение файлов этого чата в S3")
        .accessibilityLabel("Сохранение файлов этого чата в S3")
        .accessibilityValue(policy.isBusy ? "Настройка загружается" : policy.enabled.map { $0 ? "Включено" : "Выключено" } ?? "Настройка недоступна")
        .accessibilityIdentifier("telegram.chat.fileStorage")
    }
}
