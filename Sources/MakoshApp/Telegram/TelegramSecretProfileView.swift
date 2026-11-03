import SwiftUI
import MakoshTelegram

struct TelegramSecretProfileView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject var controller: TelegramSecretChatController
    let chatID: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var verificationPresented = false
    @State private var timerPresented = false
    private var session: TelegramSecretSessionSnapshot? {
        guard model.selectedChatID == chatID, model.composerSecretSession?.chatID == chatID else { return nil }
        return model.composerSecretSession
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Секретный чат").font(.headline); Spacer(); Button("Закрыть") { dismiss() } }
                .padding().accessibilityIdentifier("telegram.secret.profile.header")
            Divider()
            if let session {
                Form {
                    Section {
                        HStack(spacing: 18) {
                            TelegramChatAvatar(title: session.title, peerID: session.regularPeerID, store: model.avatars, size: 72)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.title).font(.title2)
                                Label(stateName(session.state), systemImage: "lock.fill").foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 12)
                    }
                    Section {
                        Button("Ключ шифрования") { verificationPresented = true }
                            .disabled(session.verification == nil).accessibilityIdentifier("telegram.secret.profile.key")
                        Button("Таймер удаления сообщений") { timerPresented = true }
                            .disabled(!session.canSetTTL).accessibilityIdentifier("telegram.secret.profile.timer")
                        LabeledContent("Текущий таймер", value: session.ttl.map { "\($0) с" } ?? "Выключен")
                    }
                    Section {
                        Text("Сообщения и наблюдавшиеся версии сохраняются в постоянном архиве Макоша, в том числе после удаления и срабатывания таймера Telegram. Сохранение файлов в S3 определяется флагом этого чата.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            } else {
                ContentUnavailableView("Состояние чата недоступно", systemImage: "lock", description: Text("Обновите сведения о текущем секретном сеансе."))
                Button("Обновить", action: controller.refreshSession).disabled(controller.isSettingTTL).padding()
            }
        }.frame(width: 480, height: 490)
            .sheet(isPresented: $verificationPresented) {
                if session?.verification != nil, let secret = model.conversationCapabilities?.secret { TelegramSecretVerificationView(secret: secret) }
                else { Text("Ключ текущего сеанса недоступен").padding(30) }
            }
            .sheet(isPresented: $timerPresented) { TelegramSecretTimerView(controller: controller, synthetic: model.isSyntheticPreview) }
            .onChange(of: model.selectedChatID) { _, id in if id != chatID { dismiss() } }
    }
    private func stateName(_ state: TelegramSecretConversation.State) -> String {
        switch state { case .handshake: "Ожидание подключения"; case .active: "Сквозное шифрование"; case .terminated: "Сеанс завершён" }
    }
}
