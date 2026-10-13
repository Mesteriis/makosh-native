import SwiftUI
import AppKit
import MakoshCore
import MakoshTelegram
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var telegramNotificationRouter = TelegramSystemNotificationRouter()
    lazy var telegramProxy = TelegramProxyController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct MakoshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Макош") {
            Group {
            #if DEBUG
            if Bundle.main.object(forInfoDictionaryKey: "MakoshRequiresSyntheticConfiguration") as? Bool == true,
               !telegramSyntheticLaunchAdmitted(arguments: CommandLine.arguments) {
                Text("Для синтетической проверки нужны явный режим и отдельная конфигурация PostgreSQL. Перезапустите QA через её сценарий запуска.")
                    .padding(24).frame(minWidth: 600, minHeight: 240)
                    .accessibilityIdentifier("telegram.qa.configurationRequired")
            } else if CommandLine.arguments.contains("--telegram-drafts-synthetic-preview") {
                TelegramDraftsSyntheticPreviewView().frame(minWidth: 1000, minHeight: 640)
            } else if CommandLine.arguments.contains("--telegram-secret-chats-synthetic-preview") || CommandLine.arguments.contains("--telegram-group-synthetic-preview") || CommandLine.arguments.contains("--telegram-avatar-synthetic-preview") || CommandLine.arguments.contains("--telegram-server-draft-synthetic-preview") || CommandLine.arguments.contains("--telegram-extended-messages-synthetic-preview") || CommandLine.arguments.contains("--telegram-secret-synthetic-preview") || CommandLine.arguments.contains("--telegram-paid-send-synthetic-preview") || CommandLine.arguments.contains("--telegram-dossier-synthetic-preview") || CommandLine.arguments.contains("--telegram-history-read-synthetic-preview") || CommandLine.arguments.contains("--telegram-peer-profiles-synthetic-preview") || CommandLine.arguments.contains("--telegram-peer-appearance-synthetic-preview") {
                WorkspaceView(syntheticTelegram: CommandLine.arguments.contains("--telegram-secret-chats-synthetic-preview") ? .syntheticSecretChatsPreview() : CommandLine.arguments.contains("--telegram-group-synthetic-preview") ? .syntheticGroupMembershipPreview() : CommandLine.arguments.contains("--telegram-avatar-synthetic-preview") ? .syntheticAvatarEditingPreview() : (CommandLine.arguments.contains("--telegram-server-draft-synthetic-preview") || CommandLine.arguments.contains("--telegram-extended-messages-synthetic-preview") || CommandLine.arguments.contains("--telegram-secret-synthetic-preview") || CommandLine.arguments.contains("--telegram-paid-send-synthetic-preview"))
                    ? .syntheticExtendedMessagesPreview(specialConversation: CommandLine.arguments.contains("--telegram-server-draft-synthetic-preview") ? "draft" : CommandLine.arguments.contains("--telegram-secret-synthetic-preview") ? "secret" : CommandLine.arguments.contains("--telegram-paid-send-synthetic-preview") ? "paid" : nil) : CommandLine.arguments.contains("--telegram-history-read-synthetic-preview")
                    ? .syntheticHistoryReadPreview() : CommandLine.arguments.contains("--telegram-peer-appearance-synthetic-preview")
                    ? .syntheticPeerAppearancePreview() : CommandLine.arguments.contains("--telegram-peer-profiles-synthetic-preview")
                    ? .syntheticPeerProfilesPreview() : .syntheticPreview(twoStepResetWaitSeconds: CommandLine.arguments.contains("--telegram-two-step-short-reset") ? 20 : 7 * 86400, dataSettings: CommandLine.arguments.contains("--telegram-data-settings-fixture"), privacyPremium: !CommandLine.arguments.contains("--telegram-privacy-basic-fixture")))
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Label("СИНТЕТИЧЕСКАЯ ПРОВЕРКА", systemImage: "testtube.2")
                                .font(.caption.bold())
                                .help("Отдельная схема PostgreSQL; личные аккаунты, сеть Telegram и отправка не используются")
                        }
                    }.frame(minWidth: 1000, minHeight: 640)
            } else if CommandLine.arguments.contains("--telegram-s3-synthetic-preview") {
                TelegramS3SyntheticPreview().frame(minWidth: 1000,minHeight: 640)
            } else if CommandLine.arguments.contains("--telegram-synthetic-preview") {
                TelegramSyntheticPreviewView().frame(minWidth: 1000, minHeight: 640)
            } else {
                WorkspaceView(proxy: delegate.telegramProxy).frame(minWidth: 1000, minHeight: 640)
            }
            #else
            WorkspaceView(proxy: delegate.telegramProxy).frame(minWidth: 1000, minHeight: 640)
            #endif
            }.environmentObject(delegate.telegramNotificationRouter)
        }
            .defaultSize(width: 1200, height: 800)
            .commands { TelegramSearchCommands(); TelegramSelectionCommands() }
        Settings {
            TelegramSettingsView()
        }
    }
}
