import SwiftUI
import MakoshTelegram

struct TelegramSettingsView: View {
    @AppStorage(TelegramSendKey.preferenceKey) private var sendKeyPreference = TelegramSendKey.enter.rawValue
    @AppStorage(TelegramUploadPhotoSize.preferenceKey) private var sendLargePhotos = false
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
                Toggle("Отправлять большие фотографии", isOn: $sendLargePhotos)
                    .help("Увеличенный размер применяется к новым подготовкам фотографий.")
                    .accessibilityIdentifier("telegram.settings.sendLargePhotos")
            }
        }.formStyle(.grouped).frame(width: 440, height: 220)
    }
}
