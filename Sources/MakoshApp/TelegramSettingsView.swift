import SwiftUI
import MakoshTelegram

struct TelegramSettingsView: View {
    @StateObject private var systemAppearance = TelegramSystemAppearance()
    var sessions: TelegramSessionsController? = nil
    var webSessions: TelegramWebSessionsController? = nil
    var privacy: TelegramPrivacyController? = nil
    var blockedUsers: TelegramBlockedUsersController? = nil
    var twoStep: TelegramTwoStepController? = nil
    var notifications: TelegramNotificationController? = nil
    var autoDownload: TelegramAutoDownloadSettings? = nil
    var cache: TelegramCacheController? = nil
    var proxy: TelegramProxyController? = nil
    var avatarEditing: TelegramAvatarEditingController? = nil
    var chats: [TelegramChat] = []
    var synthetic = false
    var close: (() -> Void)? = nil
    private enum Page: String { case general = "Основные", appearance = "Оформление", devices = "Устройства", privacy = "Приватность", notifications = "Уведомления и звуки", data = "Данные и память" }
    @State private var page: Page?
    @AppStorage(TelegramLocalTheme.preferenceKey) private var theme = TelegramLocalTheme.system.rawValue
    @AppStorage(TelegramAccent.preferenceKey) private var accent = TelegramAccent.blue.rawValue
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if page != nil {
                    Button { page = nil } label: { Label("Назад", systemImage: "chevron.left") }
                        .accessibilityIdentifier("telegram.settings.back")
                }
                Spacer()
                Text(page?.rawValue ?? "Настройки Telegram").font(.headline)
                Spacer()
                if let close { Button("Готово", action: close).accessibilityIdentifier("telegram.settings.close") }
            }.padding().frame(height: 55)
            Divider()
            if synthetic { Text("Синтетический аккаунт · серверные изменения симулируются").font(.caption).foregroundStyle(.secondary).padding(10) }
            switch page {
            case .general: TelegramGeneralSettingsView()
            case .appearance: TelegramAppearanceView(systemScheme: systemAppearance.scheme)
            case .data:
                if let autoDownload, let cache, let proxy { TelegramDataSettingsView(settings: autoDownload, cache: cache, proxy: proxy) }
            case .notifications:
                if let notifications, notifications.accountID != nil { TelegramNotificationSettingsView(controller: notifications, chats: chats, synthetic: synthetic) }
                else { ContentUnavailableView("Подключите Telegram", systemImage: "bell", description: Text("Уведомления доступны для подключённого аккаунта.")) }
            case .privacy:
                if let privacy { TelegramPrivacyView(controller: privacy, blockedUsers: blockedUsers, twoStep: twoStep, avatarEditing: avatarEditing, synthetic: synthetic) }
                else { ContentUnavailableView("Откройте Telegram", systemImage: "hand.raised") }
            case .devices:
                if let sessions { TelegramSessionsView(controller: sessions, synthetic: synthetic, webSessions: webSessions) }
                else { ContentUnavailableView("Откройте Telegram", systemImage: "desktopcomputer", description: Text("Устройства доступны в настройках выбранного аккаунта Telegram.")) }
            case nil:
                Form {
                    if let avatarEditing, let accountID = avatarEditing.accountID {
                        Section {
                            TelegramAvatarEditingButton(controller: avatarEditing, target: .init(accountID: accountID, peerID: accountID, kind: .main), title: "Изменить фотографию профиля")
                        }
                    }
                    Section {
                        settingsRow(.general, symbol: "gearshape", id: "general")
                        settingsRow(.appearance, symbol: "paintpalette", id: "appearance")
                        if notifications != nil { settingsRow(.notifications, symbol: "bell", id: "notifications") }
                        if proxy != nil { settingsRow(.data, symbol: "externaldrive", id: "data") }
                        if sessions != nil { settingsRow(.devices, symbol: "desktopcomputer", id: "devices") }
                        if privacy != nil { settingsRow(.privacy, symbol: "hand.raised", id: "privacy") }
                    }
                }.formStyle(.grouped)
            }
        }.frame(width: 560, height: 630)
            .tint(TelegramAccent(preference: accent).color)
            .accentColor(TelegramAccent(preference: accent).color)
            .preferredColorScheme(telegramWorkspaceScheme(theme: theme, telegramSelected: true, system: systemAppearance.scheme))
    }
    private func settingsRow(_ value: Page, symbol: String, id: String) -> some View {
        Button { page = value } label: {
            HStack { Label(value.rawValue, systemImage: symbol); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                .frame(height: 38).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("telegram.settings.\(id)")
    }
}

private struct TelegramGeneralSettingsView: View {
    @AppStorage(TelegramSendKey.preferenceKey) private var sendKeyPreference = TelegramSendKey.enter.rawValue
    @AppStorage(TelegramUploadPhotoSize.preferenceKey) private var sendLargePhotos = false
    var body: some View {
        Form {
            Section("Сообщения") {
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
        }.formStyle(.grouped)
    }
}
