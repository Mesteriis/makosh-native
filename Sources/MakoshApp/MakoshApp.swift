import SwiftUI
import AppKit
import MakoshCore
import MakoshTelegram
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
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
            #if DEBUG
            if CommandLine.arguments.contains("--telegram-drafts-synthetic-preview") {
                TelegramDraftsSyntheticPreviewView().frame(minWidth: 1000, minHeight: 640)
            } else if CommandLine.arguments.contains("--telegram-server-draft-synthetic-preview") || CommandLine.arguments.contains("--telegram-extended-messages-synthetic-preview") || CommandLine.arguments.contains("--telegram-secret-synthetic-preview") || CommandLine.arguments.contains("--telegram-paid-send-synthetic-preview") || CommandLine.arguments.contains("--telegram-dossier-synthetic-preview") || CommandLine.arguments.contains("--telegram-history-read-synthetic-preview") || CommandLine.arguments.contains("--telegram-peer-profiles-synthetic-preview") || CommandLine.arguments.contains("--telegram-peer-appearance-synthetic-preview") {
                WorkspaceView(syntheticTelegram: (CommandLine.arguments.contains("--telegram-server-draft-synthetic-preview") || CommandLine.arguments.contains("--telegram-extended-messages-synthetic-preview") || CommandLine.arguments.contains("--telegram-secret-synthetic-preview") || CommandLine.arguments.contains("--telegram-paid-send-synthetic-preview"))
                    ? .syntheticExtendedMessagesPreview(specialConversation: CommandLine.arguments.contains("--telegram-server-draft-synthetic-preview") ? "draft" : CommandLine.arguments.contains("--telegram-secret-synthetic-preview") ? "secret" : CommandLine.arguments.contains("--telegram-paid-send-synthetic-preview") ? "paid" : nil) : CommandLine.arguments.contains("--telegram-history-read-synthetic-preview")
                    ? .syntheticHistoryReadPreview() : CommandLine.arguments.contains("--telegram-peer-appearance-synthetic-preview")
                    ? .syntheticPeerAppearancePreview() : CommandLine.arguments.contains("--telegram-peer-profiles-synthetic-preview")
                    ? .syntheticPeerProfilesPreview() : .syntheticPreview())
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
                WorkspaceView().frame(minWidth: 1000, minHeight: 640)
            }
            #else
            WorkspaceView().frame(minWidth: 1000, minHeight: 640)
            #endif
        }
            .defaultSize(width: 1200, height: 800)
            .commands { TelegramSearchCommands(); TelegramSelectionCommands() }
        Settings {
            TelegramSettingsView()
        }
    }
}
