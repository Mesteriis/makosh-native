import SwiftUI
import AppKit
import MakoshCore
import MakoshTelegram
import MakoshWhatsApp
import UniformTypeIdentifiers
import MakoshMail
import MakoshTelemost
import MakoshAI
import MakoshFiles

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    lazy var telegramNotificationRouter = TelegramSystemNotificationRouter(
        registerSystemDelegate:
            !(CommandLine.arguments.contains("--whatsapp-synthetic-preview")
            || Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "whatsapp"
            || CommandLine.arguments.contains("--telemost-synthetic-preview")
            || Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "telemost"
            || CommandLine.arguments.contains("--teams-synthetic-preview")
            || Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "teams"
            || CommandLine.arguments.contains(AIQAIsolation.flag) || CommandLine.arguments.contains(FilesQAIsolation.flag)
            || CommandLine.arguments.contains(TasksHost.qaFlag)))
    lazy var telegramProxy = TelegramProxyController()
    let telegramCallCoordinator = TelegramCallCoordinator()
    let telegramCallWindows = TelegramCallWindows()
    let whatsappSettings = WhatsAppSettingsRegistry()
    let teamsSettings = TeamsSettingsRegistry()
    lazy var ai = AIHost()
    lazy var files = FilesHost()
    lazy var tasks = TasksHost()
    private var instanceLock: MakoshInstanceLock?
    /// One running copy per bundle: a second launch brings the first one forward and quits.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        instanceLock = MakoshInstanceLock.acquire(at: MakoshInstanceLock.defaultURL(bundleIdentifier: identifier))
        guard instanceLock == nil else { return }
        let current = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != current }?.activate()
        exit(0)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct MakoshApp: App {
    static func permitsOrdinaryReleaseLaunch(marker: String?, requiresSynthetic: Bool, arguments: [String]) -> Bool {
        WhatsAppQAIsolation.permitsNormalLaunch(marker: marker, arguments: arguments)
            && TelemostSyntheticLaunchPolicy.permitsNormalLaunch(marker: marker, arguments: arguments)
            && !arguments.contains("--teams-synthetic-preview") && !arguments.contains(AIQAIsolation.flag)
            && !arguments.contains(FilesQAIsolation.flag) && !arguments.contains(TasksHost.qaFlag) && !requiresSynthetic
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// The settings tab to show; a menu item may set it before opening the window.
    @AppStorage(MakoshSettingsTab.key) private var settingsTab = "telegram"
    var body: some Scene {
        WindowGroup("Макош") {
            Group {
                #if DEBUG
                if Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "whatsapp",
                    !CommandLine.arguments.contains("--whatsapp-synthetic-preview")
                {
                    Text("WhatsApp QA требует явную отдельную конфигурацию.").padding(24)
                } else if !TelemostSyntheticLaunchPolicy.permitsNormalLaunch(
                    marker: Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String, arguments: CommandLine.arguments),
                    !CommandLine.arguments.contains("--telemost-synthetic-preview")
                {
                    Text("Телемост QA требует явную синтетическую конфигурацию.").padding(24)
                } else if CommandLine.arguments.contains("--telemost-synthetic-preview") {
                    TelemostSyntheticPreview().frame(minWidth: 1100, minHeight: 720)
                } else if Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "ai",
                    !CommandLine.arguments.contains(AIQAIsolation.flag)
                {
                    Text("ИИ QA требует --ai-synthetic-preview и отдельную конфигурацию PostgreSQL.").padding(24).frame(
                        minWidth: 600, minHeight: 240)
                } else if CommandLine.arguments.contains(AIQAIsolation.flag) {
                    AISyntheticPreview().frame(minWidth: 1000, minHeight: 680)
                } else if Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "files",
                    !CommandLine.arguments.contains(FilesQAIsolation.flag)
                {
                    Text("QA «Файлы» требует --files-synthetic-preview и отдельную конфигурацию PostgreSQL.").padding(24).frame(
                        minWidth: 600, minHeight: 240)
                } else if CommandLine.arguments.contains(FilesQAIsolation.flag) {
                    FilesSyntheticPreview().frame(minWidth: 1000, minHeight: 680)
                } else if Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "tasks",
                    !CommandLine.arguments.contains(TasksHost.qaFlag)
                {
                    Text("QA «Задачи» требует --tasks-synthetic-preview и отдельную конфигурацию PostgreSQL.").padding(24).frame(
                        minWidth: 600, minHeight: 240)
                } else if CommandLine.arguments.contains(TasksHost.qaFlag) {
                    TasksSyntheticPreview().frame(minWidth: 1100, minHeight: 700)
                } else if Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "teams",
                    !CommandLine.arguments.contains("--teams-synthetic-preview")
                {
                    Text("Teams QA требует --teams-synthetic-preview и отдельную конфигурацию PostgreSQL.").padding(24).frame(
                        minWidth: 650, minHeight: 260)
                } else if CommandLine.arguments.contains("--teams-synthetic-preview") {
                    TeamsSyntheticPreview().frame(minWidth: 1050, minHeight: 720)
                } else if CommandLine.arguments.contains("--whatsapp-synthetic-preview") {
                    WhatsAppOpenQuestionsPreview().frame(minWidth: 1100, minHeight: 720)
                } else if CommandLine.arguments.contains("--telegram-layout-synthetic-preview") {
                    WorkspaceView(syntheticTelegram: .syntheticWorkspaceLayoutPreview())
                } else if CommandLine.arguments.contains("--mail-synthetic-preview") {
                    WorkspaceView(syntheticMail: MailWorkspaceModel(synthetic: true)).frame(minWidth: 1100, minHeight: 720)
                } else if Bundle.main.object(forInfoDictionaryKey: "MakoshRequiresSyntheticConfiguration") as? Bool == true,
                    !telegramSyntheticLaunchAdmitted(arguments: CommandLine.arguments)
                {
                    Text(
                        "Для синтетической проверки нужны явный режим и отдельная конфигурация PostgreSQL. Перезапустите QA через её сценарий запуска."
                    )
                    .padding(24).frame(minWidth: 600, minHeight: 240)
                    .accessibilityIdentifier("telegram.qa.configurationRequired")
                } else if CommandLine.arguments.contains("--telegram-drafts-synthetic-preview") {
                    TelegramDraftsSyntheticPreviewView().frame(minWidth: 1000, minHeight: 640)
                } else if CommandLine.arguments.contains("--telegram-calls-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-secret-chats-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-group-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-avatar-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-server-draft-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-extended-messages-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-secret-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-paid-send-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-dossier-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-history-read-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-peer-profiles-synthetic-preview")
                    || CommandLine.arguments.contains("--telegram-peer-appearance-synthetic-preview")
                {
                    WorkspaceView(
                        syntheticTelegram: CommandLine.arguments.contains("--telegram-qr-qa")
                            ? .syntheticQRLoginPreview()
                            : CommandLine.arguments.contains("--telegram-calls-synthetic-preview")
                                ? .syntheticCallsPreview()
                                : CommandLine.arguments.contains("--telegram-secret-chats-synthetic-preview")
                                    ? .syntheticSecretChatsPreview()
                                    : CommandLine.arguments.contains("--telegram-group-synthetic-preview")
                                        ? .syntheticGroupMembershipPreview()
                                        : CommandLine.arguments.contains("--telegram-avatar-synthetic-preview")
                                            ? .syntheticAvatarEditingPreview()
                                            : (CommandLine.arguments.contains("--telegram-server-draft-synthetic-preview")
                                                || CommandLine.arguments.contains("--telegram-extended-messages-synthetic-preview")
                                                || CommandLine.arguments.contains("--telegram-secret-synthetic-preview")
                                                || CommandLine.arguments.contains("--telegram-paid-send-synthetic-preview"))
                                                ? .syntheticExtendedMessagesPreview(
                                                    specialConversation: CommandLine.arguments.contains(
                                                        "--telegram-server-draft-synthetic-preview")
                                                        ? "draft"
                                                        : CommandLine.arguments.contains("--telegram-secret-synthetic-preview")
                                                            ? "secret"
                                                            : CommandLine.arguments.contains("--telegram-paid-send-synthetic-preview")
                                                                ? "paid" : nil)
                                                : CommandLine.arguments.contains("--telegram-history-read-synthetic-preview")
                                                    ? .syntheticHistoryReadPreview()
                                                    : CommandLine.arguments.contains("--telegram-peer-appearance-synthetic-preview")
                                                        ? .syntheticPeerAppearancePreview()
                                                        : CommandLine.arguments.contains("--telegram-peer-profiles-synthetic-preview")
                                                            ? .syntheticPeerProfilesPreview()
                                                            : .syntheticPreview(
                                                                twoStepResetWaitSeconds: CommandLine.arguments.contains(
                                                                    "--telegram-two-step-short-reset") ? 20 : 7 * 86400,
                                                                dataSettings: CommandLine.arguments.contains(
                                                                    "--telegram-data-settings-fixture"),
                                                                privacyPremium: !CommandLine.arguments.contains(
                                                                    "--telegram-privacy-basic-fixture"))
                    )
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Label("СИНТЕТИЧЕСКАЯ ПРОВЕРКА", systemImage: "testtube.2")
                                .font(.caption.bold())
                                .help("Отдельная схема PostgreSQL; личные аккаунты, сеть Telegram и отправка не используются")
                        }
                    }.frame(minWidth: 1000, minHeight: 640)
                } else if CommandLine.arguments.contains("--telegram-s3-synthetic-preview") {
                    TelegramS3SyntheticPreview().frame(minWidth: 1000, minHeight: 640)
                } else if CommandLine.arguments.contains("--telegram-synthetic-preview") {
                    TelegramSyntheticPreviewView().frame(minWidth: 1000, minHeight: 640)
                } else {
                    WorkspaceView(proxy: delegate.telegramProxy, callCoordinator: delegate.telegramCallCoordinator).frame(
                        minWidth: 1000, minHeight: 640)
                }
                #else
                if !Self.permitsOrdinaryReleaseLaunch(
                    marker: Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String,
                    requiresSynthetic: Bundle.main.object(forInfoDictionaryKey: "MakoshRequiresSyntheticConfiguration") as? Bool == true,
                    arguments: CommandLine.arguments)
                {
                    Text("Эта сборка не поддерживает синтетический запуск. Используйте отдельную debug-сборку QA.").padding(24)
                } else {
                    WorkspaceView(proxy: delegate.telegramProxy, callCoordinator: delegate.telegramCallCoordinator).frame(
                        minWidth: 1000, minHeight: 640)
                }
                #endif
            }.makoshAppearance().environmentObject(delegate.telegramNotificationRouter).environmentObject(delegate.telegramCallWindows)
                .environmentObject(delegate.whatsappSettings).environmentObject(delegate.teamsSettings).environmentObject(delegate.ai)
                .environmentObject(delegate.files).environment(\.filesHost, delegate.files)
                .environmentObject(delegate.tasks).environment(\.tasksHost, delegate.tasks)
        }
        .defaultSize(width: 1200, height: 854)
        .windowResizability(.contentMinSize)
        .commands {
            TelegramSearchCommands()
            TelegramSelectionCommands()
        }
        Settings {
            Group {
                if CommandLine.arguments.contains("--whatsapp-synthetic-preview")
                    || Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "whatsapp"
                {
                    Text("WhatsApp QA · без провайдера, системных уведомлений и устройств.").padding(24)
                } else if CommandLine.arguments.contains("--telemost-synthetic-preview")
                    || Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "telemost"
                {
                    Text("Телемост QA · подставной API и обработчик ссылок; остальные сервисы выключены.").padding(24)
                } else if CommandLine.arguments.contains("--teams-synthetic-preview")
                    || Bundle.main.object(forInfoDictionaryKey: "MakoshSyntheticService") as? String == "teams"
                {
                    TeamsCommonSettingsView()
                } else if CommandLine.arguments.contains(AIQAIsolation.flag) {
                    Text("ИИ QA · настройки внутри окна проверки; остальные сервисы выключены.").padding(24)
                } else if CommandLine.arguments.contains(FilesQAIsolation.flag) {
                    Text("QA «Файлы» · подставной Paperless внутри окна проверки; остальные сервисы выключены.").padding(24)
                } else if CommandLine.arguments.contains(TasksHost.qaFlag) {
                    Text("QA «Задачи» · подставная Jira внутри окна проверки; остальные сервисы выключены.").padding(24)
                } else {
                    TabView(selection: $settingsTab) {
                        TelegramSettingsView().tabItem { Label("Telegram", systemImage: "paperplane") }.tag("telegram")
                        WhatsAppCommonSettingsView().tabItem { Label("WhatsApp", systemImage: "message") }.tag("whatsapp")
                        TeamsCommonSettingsView().tabItem { Label("Teams", systemImage: "person.3") }.tag("teams")
                        FilesSettingsView().tabItem { Label("Файлы", systemImage: "folder") }.tag(MakoshSettingsTab.files)
                        TasksSettingsView().tabItem { Label("Задачи", systemImage: "checklist") }.tag(MakoshSettingsTab.tasks)
                        AISettingsView().tabItem { Label("ИИ", systemImage: "sparkles") }.tag("ai")
                    }
                }
            }.environmentObject(delegate.whatsappSettings).environmentObject(delegate.teamsSettings).environmentObject(
                delegate.telegramNotificationRouter
            ).environmentObject(delegate.ai).environmentObject(delegate.files).environmentObject(delegate.tasks)
        }
    }
}

/// Keys for opening Settings on a given tab.
enum MakoshSettingsTab {
    static let key = "makosh.settings.tab"
    static let files = "files"
    static let tasks = "tasks"
}
