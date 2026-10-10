import SwiftUI
import MakoshTelegram

struct TelegramSettingsView: View {
    @AppStorage(TelegramSendKey.preferenceKey) private var sendKeyPreference = TelegramSendKey.enter.rawValue
    var body: some View {
        Form {
            Section("Telegram") {
                Picker("Отправка сообщений", selection: Binding(
                    get: { TelegramSendKey(preferenceValue: sendKeyPreference).rawValue },
                    set: { sendKeyPreference = $0 }
                )) {
                    Text("Отправлять по Enter").tag(TelegramSendKey.enter.rawValue)
                        .accessibilityIdentifier("telegram.settings.sendByEnter")
                    Text("Отправлять по ⌘ + Enter").tag(TelegramSendKey.commandEnter.rawValue)
                        .accessibilityIdentifier("telegram.settings.sendByCommandEnter")
                }.pickerStyle(.radioGroup)
                    .accessibilityIdentifier("telegram.settings.sendKey")
            }
        }.formStyle(.grouped).frame(width: 440, height: 180)
    }
}
