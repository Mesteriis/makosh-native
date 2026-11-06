import SwiftUI
import AppKit
import MakoshCore
import MakoshTelegram
import MakoshMail
import MakoshWhatsApp
import MakoshTeams
import MakoshTelemost
import MakoshAI
import MakoshFiles
import UniformTypeIdentifiers

private enum Destination: String, CaseIterable, Identifiable {
    case contacts = "Контакты", mail = "Почта", telegram = "Telegram", whatsapp = "WhatsApp", teams = "Teams", meetings = "Встречи",
        files = "Файлы", ai = "ИИ"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .contacts: "person.2"
        case .mail: "envelope"
        case .telegram: "paperplane"
        case .whatsapp: "message"
        case .teams: "person.3"
        case .meetings: "video"
        case .files: "folder"
        case .ai: "sparkles"
        }
    }
}
private struct EditorSelection: Identifiable {
    let id = UUID()
    let contact: Contact?
}

struct WorkspaceView: View {
    @EnvironmentObject private var callWindows: TelegramCallWindows
    @EnvironmentObject private var ai: AIHost
    @EnvironmentObject private var files: FilesHost
    /// Sources for the chat panel's "+" and "@"; made once the window appears.
    @State private var aiContextSearch: AIContextSearch?
    @StateObject private var systemAppearance = TelegramSystemAppearance()
    @AppStorage(TelegramAppearancePreferences.preferenceKey) private var appearanceRaw = ""
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(TelegramLocalTheme.preferenceKey) private var telegramTheme = TelegramLocalTheme.system.rawValue
    @AppStorage(TelegramAccent.preferenceKey) private var telegramAccent = TelegramAccent.purple.rawValue
    @StateObject private var model: WorkspaceModel
    @StateObject private var mail: MailWorkspaceModel
    @StateObject private var telegram: TelegramModel
    private var isolatedWhatsApp = false
    @StateObject private var whatsapp = WhatsAppWorkspaceModel()
    @StateObject private var whatsappNavigation = WhatsAppWorkspaceNavigationState()
    @StateObject private var teams = TeamsWorkspaceModel()
    @StateObject private var telemost = TelemostWorkspaceModel()
    @State private var telemostDossierRequest = UUID()
    @State private var destination: Destination? = .contacts
    @State private var sidebarWidths: [Destination: CGFloat] = [:]
    @State private var teamsDossierRequest = UUID()
    private var telegramAppearance: TelegramAppearancePreferences { (try? .decode(appearanceRaw)) ?? .init() }
    private var resolvedTelegramScheme: ColorScheme {
        telegramWorkspaceScheme(
            theme: telegramTheme, telegramSelected: true, system: .dark, night: telegramAppearance.night, date: systemAppearance.now,
            cloudDark: telegramAppearance.cloudPalette?.isDark)
    }
    private var resolvedTelegramAccent: Color {
        telegramAppearance.effectivePalette(isDark: resolvedTelegramScheme == .dark).map { telegramPaletteColor($0, "accent", $0.accent) }
            ?? TelegramAccent(preference: telegramAccent).color
    }
    @State private var search = ""
    @State private var editor: EditorSelection?
    @State private var review = false
    init(proxy: TelegramProxyController? = nil, callCoordinator: TelegramCallCoordinator? = nil) {
        _mail = StateObject(wrappedValue: MailWorkspaceModel())
        let dossier = WorkspaceModel()
        _model = StateObject(wrappedValue: dossier)
        _telemost = StateObject(wrappedValue: TelemostWorkspaceModel(service: TelemostWorker(contacts: dossier.dossierWorker)))
        _telegram = StateObject(wrappedValue: TelegramModel(proxy: proxy, calls: TelegramCallController(coordinator: callCoordinator)))
    }
    #if DEBUG
    init(syntheticTelemost: TelemostWorkspaceModel, dossier: WorkspaceModel) {
        _model = StateObject(wrappedValue: dossier)
        _telemost = StateObject(wrappedValue: syntheticTelemost)
        _mail = StateObject(wrappedValue: MailWorkspaceModel(synthetic: true))
        _telegram = StateObject(wrappedValue: .syntheticPreview())
        _whatsapp = StateObject(wrappedValue: WhatsAppWorkspaceModel(synthetic: true))
        _teams = StateObject(wrappedValue: TeamsWorkspaceModel(worker: TeamsWorker.synthetic(), polling: false, synthetic: true))
        _destination = State(initialValue: .meetings)
    }
    init(syntheticTeams: TeamsWorkspaceModel) {
        _model = StateObject(wrappedValue: WorkspaceModel(requireExplicitDatabaseConfiguration: true, syntheticSchemaPrefix: "qa_teams_"))
        _mail = StateObject(wrappedValue: MailWorkspaceModel(synthetic: true))
        _telegram = StateObject(wrappedValue: .syntheticPreview())
        _whatsapp = StateObject(wrappedValue: WhatsAppWorkspaceModel(synthetic: true))
        _teams = StateObject(wrappedValue: syntheticTeams)
        _destination = State(initialValue: .teams)
    }
    init(syntheticWhatsApp: WhatsAppWorkspaceModel) {
        isolatedWhatsApp = true
        _model = StateObject(
            wrappedValue: WorkspaceModel(requireExplicitDatabaseConfiguration: true, syntheticSchemaPrefix: "qa_whatsapp_"))
        _mail = StateObject(wrappedValue: MailWorkspaceModel(synthetic: true))
        _telegram = StateObject(wrappedValue: .syntheticPreview())
        _whatsapp = StateObject(wrappedValue: syntheticWhatsApp)
        _destination = State(initialValue: .whatsapp)
    }
    init(syntheticMail: MailWorkspaceModel) {
        _model = StateObject(wrappedValue: WorkspaceModel(requireExplicitDatabaseConfiguration: true, syntheticSchemaPrefix: "qa_mail_"))
        _mail = StateObject(wrappedValue: syntheticMail)
        _telegram = StateObject(wrappedValue: .syntheticPreview())
        _destination = State(initialValue: .mail)
    }
    init(syntheticTelegram: TelegramModel) {
        _mail = StateObject(wrappedValue: MailWorkspaceModel())
        _model = StateObject(wrappedValue: WorkspaceModel(requireExplicitDatabaseConfiguration: true))
        _telegram = StateObject(wrappedValue: syntheticTelegram)
        _destination = State(initialValue: .telegram)
    }
    #endif
    var body: some View {
        VStack(spacing: 0) {
            if destination == .mail {
                MailNavigationBar(model: mail)
                Divider()
            }
            if destination == .telegram {
                TelegramWorkspaceNavigation(model: telegram)
                Divider()
            }
            if destination == .whatsapp {
                WhatsAppWorkspaceNavigation(model: whatsapp, navigation: whatsappNavigation)
                Divider()
            }
            HStack(spacing: 0) {
                if destination == .telegram, telegram.phase == .ready { TelegramFolderRail(model: telegram) }
                WorkspaceSplitView(
                    width: sidebarWidth, minimum: sidebarLayout.min, maximum: sidebarLayout.max,
                    minimumDetail: destination == .telegram || destination == .whatsapp || (destination == .mail && mail.showDossier)
                        ? 640 : 460
                ) {
                    sectionSidebar.background { WorkspaceBackdrop(intensity: 0.55) }
                } detail: {
                    sectionDetail.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                MakoshMenu {
                    MakoshPicker("Раздел", selection: $destination) {
                        ForEach(Destination.allCases.filter { !isolatedWhatsApp || $0 == .contacts || $0 == .whatsapp }) { item in
                            Label(item.rawValue, systemImage: item.symbol).tag(Optional(item))
                        }
                    }.pickerStyle(.inline).labelsHidden()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: destination?.symbol ?? "square.grid.2x2").foregroundStyle(WorkspaceStyle.accent)
                        Text(destination?.rawValue ?? "Раздел").foregroundStyle(.primary)
                    }.font(.system(size: 14, weight: .medium))
                }
                .makoshMenuStyle(.plain).makoshMenuIndicator(.visible).makoshMenuWidth(220).fixedSize()
                .help("Переключить раздел").accessibilityIdentifier("workspace.sectionMenu")
                .accessibilityLabel("Раздел: \(destination?.rawValue ?? "не выбран")")
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) { Text("Макош").font(.headline) }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Настройки Макоша").accessibilityIdentifier("workspace.settings")
            }.sharedBackgroundVisibility(.hidden)
        }
        .onAppear {
            if aiContextSearch == nil {
                let search = AIContextSearch(telegram: telegram, whatsapp: whatsapp, mail: mail) { [model] in model.contacts }
                let filesModel = files.model
                search.attach(
                    files: FilePickerSearch(
                        catalogue: { filesModel.items },
                        paperless: { connectionID, query in
                            guard let client = await filesModel.client(for: connectionID) else { return [] }
                            return try await client.documents(query: query, page: 1).items
                        }, connections: { filesModel.connections.map(\.id) }))
                aiContextSearch = search
            }
            if !isolatedWhatsApp && !teams.isSynthetic && !telemost.isSynthetic {
                callWindows.register(telegram.calls, synthetic: telegram.isSyntheticPreview, avatars: telegram.avatars)
            }
        }
        .onDisappear {
            callWindows.unregister(telegram.calls)
            Task { await whatsapp.calls.end() }
        }
        .makoshAppearance()
        .toolbarBackground(WorkspaceStyle.base, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
        .modifier(
            OtherCommunicationHosts(
                telegram: telegram, mail: mail, whatsapp: whatsapp,
                enabled: !isolatedWhatsApp && !teams.isSynthetic && !telemost.isSynthetic)
        )
        .modifier(TelemostGuardedTeamsHosts(model: teams, enabled: !isolatedWhatsApp && !telemost.isSynthetic))
        .modifier(WhatsAppQAHosts(model: whatsapp, enabled: isolatedWhatsApp))
        .onReceive(telegram.notifications.$activationRequest.dropFirst()) { _ in destination = .telegram }
        .onReceive(whatsapp.$notificationActivation.dropFirst()) { _ in destination = .whatsapp }
        .onReceive(mail.$notificationActivation.dropFirst()) { _ in destination = .mail }
        .onReceive(teams.$notificationActivation.dropFirst()) { _ in destination = .teams }
        .task {
            await model.load()
            if let configuration = model.mailConfiguration, ordinaryLaunch {
                files.start(
                    configuration: configuration,
                    resolver: FileSourceBridge(telegram: telegram, whatsapp: whatsapp, mail: mail, teams: teams))
                Task {
                    await ai.start(
                        configuration: configuration, contacts: model.dossierWorker, telegram: { [telegram] in telegram.aiContextReader },
                        whatsapp: { [whatsapp] in whatsapp.service }, files: files)
                }
            }
            if ordinaryLaunch { telegram.connectIfRemembered() }
            if let configuration = model.mailConfiguration {
                if !whatsapp.isSynthetic && !teams.isSynthetic && !telemost.isSynthetic { await mail.load(configuration: configuration) }
                // Remembered WhatsApp accounts reconnect at launch, not only when the tab opens.
                if ordinaryLaunch, !MakoshAutoConnect(scope: configuration.schema).remembered("whatsapp").isEmpty {
                    await whatsapp.load(configuration: configuration)
                }
                if destination == .whatsapp && !teams.isSynthetic && !telemost.isSynthetic {
                    await whatsapp.load(configuration: configuration)
                }
                if destination == .teams && !isolatedWhatsApp && !telemost.isSynthetic { await teams.load(configuration: configuration) }
                if destination == .meetings && !isolatedWhatsApp { await telemost.start(configuration: configuration) }
            }
        }
        .onChange(of: teams.selectedScope) { _, _ in teamsDossierRequest = UUID() }
        .onChange(of: destination) { _, selected in
            teamsDossierRequest = UUID()
            telemostDossierRequest = UUID()
            if selected == .meetings, !mail.synthetic, !whatsapp.isSynthetic, !teams.isSynthetic,
                let configuration = model.mailConfiguration
            {
                Task { await telemost.start(configuration: configuration) }
            }
            if selected == .teams, !isolatedWhatsApp, !telemost.isSynthetic, let configuration = model.mailConfiguration {
                Task { await teams.load(configuration: configuration) }
            }
            if selected == .whatsapp, !teams.isSynthetic, !telemost.isSynthetic, let configuration = model.mailConfiguration {
                Task { await whatsapp.load(configuration: configuration) }
            }
        }
        .onChange(of: model.ready) { _, ready in
            guard ready, !isolatedWhatsApp, !teams.isSynthetic, !telemost.isSynthetic else { return }
            model.configureArchive(telegram.archive, synthetic: telegram.isSyntheticPreview)
            #if DEBUG
            if telegram.isSyntheticPreview { model.configurePendingUploadRecoveryQAIfRequested(telegram) }
            #endif
        }
        .onAppear {
            guard !isolatedWhatsApp, !teams.isSynthetic, !telemost.isSynthetic else { return }
            model.configureArchive(telegram.archive, synthetic: telegram.isSyntheticPreview)
            #if DEBUG
            if telegram.isSyntheticPreview { model.configurePendingUploadRecoveryQAIfRequested(telegram) }
            #endif
        }
        .sheet(item: $editor) { selection in ContactEditor(contact: selection.contact, model: model).makoshAppearance() }
        .sheet(item: $files.pendingSend) { request in PaperlessSendSheet(model: files.model, request: request).makoshAppearance() }
        .sheet(isPresented: $review) { MergeReviewView(model: model).makoshAppearance() }
        .alert("Макош", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Понятно", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .overlay(alignment: .bottomTrailing) {
            if let notice = model.notice {
                HStack {
                    Text(notice)
                    Button {
                        model.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(20)
            }
        }
        .frame(minWidth: destination == .telegram || destination == .whatsapp ? 1160 : destination == .mail ? 1040 : nil)
    }
    /// The AI panel beside a Telegram chat, when the AI and the account are ready.
    private var telegramAIPanel: ((Int64, String, @escaping () -> Void) -> AnyView)? {
        guard let search = aiContextSearch, ai.configuration != nil, let account = telegram.aiContextAccountID else { return nil }
        return { chatID, title, close in
            AnyView(
                AIChatPanelView(
                    model: ai.panel, search: search,
                    anchor: .chat(service: "telegram", accountID: String(account), chatID: String(chatID), title: title, range: .standard),
                    openCard: openAICard,
                    openInSection: {
                        let id = ai.panel.selectedConversationID
                        destination = .ai
                        Task {
                            await ai.workspace.reload()
                            await ai.workspace.select(id)
                        }
                    }, close: close))
        }
    }

    /// Opens the chat or section a catalogue file came from.
    private func openFileSource(_ identity: MessageArchiveIdentity) {
        switch identity.service {
        case "telegram":
            guard String(telegram.aiContextAccountID ?? 0) == identity.accountID, let id = Int64(identity.conversationID) else { return }
            destination = .telegram
            telegram.selectedChatID = id
        case "whatsapp":
            guard whatsapp.selectedAccountID?.uuidString == identity.accountID else { return }
            destination = .whatsapp
            Task { await whatsapp.selectChat(identity.conversationID) }
        case "mail": destination = .mail
        case "teams": destination = .teams
        default: break
        }
    }

    /// Opens an attached source in its own section.
    private func openAICard(_ card: AIContextCard) {
        switch card {
        case .chat("telegram", let accountID, let chatID, _, _):
            guard String(telegram.aiContextAccountID ?? 0) == accountID, let id = Int64(chatID) else { return }
            destination = .telegram
            telegram.selectedChatID = id
        case .chat("whatsapp", _, let chatID, _, _):
            destination = .whatsapp
            Task { await whatsapp.selectChat(chatID) }
        case .chat: break
        case .file(let source, _, _):
            destination = .files
            switch source {
            case .archive(let recordID):
                files.model.source = .all
                files.model.highlighted = recordID
            case .paperless(let connectionID, _): files.model.source = .storage(connectionID)
            case .staged: break
            }
        case .letter:
            // The letter itself is not yet selected there.
            destination = .mail
        case .contact(let id, _):
            Task { if await model.selectContact(id) { destination = .contacts } }
        }
    }

    /// AI starts only in the ordinary app; every service QA preview keeps it off.
    private var ordinaryLaunch: Bool {
        !isolatedWhatsApp && !mail.synthetic && !whatsapp.isSynthetic && !teams.isSynthetic && !telemost.isSynthetic
            && !telegram.isSyntheticPreview
    }
    private var sidebarLayout: (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        switch destination {
        case .mail: (320, 400, 420)
        case .teams: (280, 330, 440)
        case .meetings: (300, 340, 440)
        case .whatsapp: (300, 350, 440)
        default: (280, 320, 390)
        }
    }
    private var sidebarWidth: Binding<CGFloat> {
        Binding(
            get: { sidebarWidths[destination ?? .contacts] ?? sidebarLayout.ideal },
            set: { sidebarWidths[destination ?? .contacts] = $0 })
    }
    @ViewBuilder private var sectionSidebar: some View {
        if destination == .contacts {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Контакты").font(.title2.bold())
                        Text("\(model.contacts.count) в вашей картотеке").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        editor = EditorSelection(contact: nil)
                    } label: {
                        Image(systemName: "plus")
                    }.help("Новый контакт").accessibilityIdentifier("contacts.create").disabled(!model.canWrite)
                }.padding(20)
                TextField("Поиск по имени, компании, почте", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(
                    .bottom, 12
                ).accessibilityIdentifier("contacts.search")
                Divider()
                if model.contacts.isEmpty {
                    ContentUnavailableView(
                        "Пока нет контактов", systemImage: "person.crop.rectangle.stack",
                        description: Text("Создайте контакт или импортируйте JSON-файл.")
                    ).frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                } else {
                    List(selection: $model.selectedID) {
                        ForEach(filteredContacts) { contact in
                            HStack(spacing: 12) {
                                Avatar(name: contact.displayName)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(contact.displayName).font(.headline)
                                    Text(contact.organization.isEmpty ? (contact.emails.first ?? "Личный контакт") : contact.organization)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(.vertical, 8).tag(contact.id).accessibilityIdentifier("contact.row.\(contact.id)")
                        }
                    }.listStyle(.inset).scrollContentBackground(.hidden)
                }
                Divider()
                VStack(spacing: 10) {
                    Button(action: chooseImportFile) {
                        Label("Импортировать JSON", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }.accessibilityIdentifier("contacts.import").disabled(!model.canWrite)
                    Button {
                        review = true
                    } label: {
                        Label("Объединения · \(model.duplicates.count)", systemImage: "person.2.badge.gearshape").frame(maxWidth: .infinity)
                    }.accessibilityIdentifier("contacts.duplicates").disabled(!model.canWrite)
                }.padding(16)
            }.frame(maxHeight: .infinity, alignment: .top).background { WorkspaceBackdrop(intensity: 0.55) }.frame(
                minWidth: 280, idealWidth: 320, maxWidth: 390)
        } else if destination == .mail {
            MailMessageListView(model: mail).frame(minWidth: 320, idealWidth: 400, maxWidth: 420)
        } else if destination == .telegram {
            TelegramSidebarView(model: telegram, backupContext: model.archiveBackupContext).frame(
                minWidth: 280, idealWidth: 320, maxWidth: 390)
        } else if destination == .teams {
            TeamsSidebarView(model: teams).frame(minWidth: 280, idealWidth: 330, maxWidth: 440)
        } else if destination == .meetings {
            TelemostCatalogueView(model: telemost).frame(minWidth: 300, idealWidth: 340, maxWidth: 440)
        } else if destination == .whatsapp {
            WhatsAppSidebarView(model: whatsapp, navigation: whatsappNavigation).frame(minWidth: 300, idealWidth: 350, maxWidth: 440)
        } else if destination == .files {
            FilesSidebarView(model: files.model, host: files).frame(minWidth: 280, idealWidth: 320, maxWidth: 390)
        } else if destination == .ai {
            AIConversationListView(model: ai.workspace, openChat: openAICard).frame(minWidth: 280, idealWidth: 320, maxWidth: 390)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Label(destination?.rawValue ?? "", systemImage: destination?.symbol ?? "square").font(.title2.bold())
                Label("Не подключено", systemImage: "circle.dashed").foregroundStyle(.secondary)
                Text(
                    destination == .meetings
                        ? "Откройте встречу в Яндекс Телемосте по своей ссылке."
                        : "Подключение сервиса ещё не реализовано. Ваши аккаунты не запрашиваются."
                ).foregroundStyle(.secondary)
                Spacer()
            }.padding(24).frame(minWidth: 280, idealWidth: 320, maxWidth: 390)
        }
    }
    private var sectionDetail: some View {
        VStack(spacing: 0) {
            TelegramCallCompactView(controller: telegram.calls)
            Group {
                if destination == .contacts {
                    if let contact = model.selected {
                        DossierView(contact: contact, model: model, openMeeting: telemost.openMeeting) {
                            editor = EditorSelection(contact: contact)
                        }
                    } else {
                        ContentUnavailableView(
                            "Всё о человеке — рядом", systemImage: "person.text.rectangle",
                            description: Text("Выберите контакт, чтобы открыть досье, заметки и источники."))
                    }
                } else if destination == .mail {
                    MailReadingView(model: mail, dossier: model) { id in
                        Task {
                            if await model.selectContact(id) {
                                mail.showDossier = false
                                destination = .contacts
                            }
                        }
                    }
                } else if destination == .telegram {
                    TelegramDetailView(
                        model: telegram, dossier: model,
                        openDossier: { id in Task { if await model.selectContact(id) { destination = .contacts } } },
                        aiPanel: telegramAIPanel)
                } else if destination == .whatsapp {
                    WhatsAppDetailView(
                        model: whatsapp,
                        dossier: {
                            guard let account = whatsapp.selectedAccountID, let chat = whatsapp.selectedChat else { return }
                            Task {
                                if let id = await model.linkWhatsAppChat(chat, accountID: account), whatsapp.selectedAccountID == account,
                                    whatsapp.selectedChatID == chat.id, await model.selectContact(id)
                                {
                                    destination = .contacts
                                }
                            }
                        }
                    ).id((whatsapp.selectedAccountID?.uuidString ?? "") + ":" + (whatsapp.selectedChatID ?? ""))
                } else if destination == .teams {
                    TeamsDetailView(model: teams) { person, scope in
                        let request = UUID()
                        teamsDossierRequest = request
                        Task {
                            let id = await model.openTeamsDossier(
                                person, accountID: scope.accountID,
                                while: {
                                    teamsDossierRequest == request && destination == .teams && teams.selectedScope == scope
                                })
                            if id != nil { destination = .contacts }
                        }
                    }.id(teams.selectedScope?.storageKey.base64EncodedString() ?? "teams-empty")
                } else if destination == .meetings {
                    TelemostDetailView(model: telemost, contacts: model.contacts) { contact in
                        let request = UUID(), window = NSApp.keyWindow
                        telemostDossierRequest = request
                        Task {
                            let id = await model.openTelemostDossier(
                                telemost, contactID: contact,
                                while: {
                                    telemostDossierRequest == request && destination == .meetings && window != nil
                                        && window === NSApp.keyWindow && window?.isVisible == true && window?.isMiniaturized == false
                                })
                            if id != nil { destination = .contacts }
                        }
                    }
                } else if destination == .files {
                    FilesDetailView(model: files.model, host: files, openSource: openFileSource)
                } else if destination == .ai {
                    AIConversationView(model: ai.workspace, openCard: openAICard) { source in
                        // Opens the source's section; the message itself is not yet selected there.
                        switch source.service {
                        case "telegram": destination = .telegram
                        case "whatsapp": destination = .whatsapp
                        case "teams": destination = .teams
                        case "mail": destination = .mail
                        default: break
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "\(destination?.rawValue ?? "Сервис") не подключён", systemImage: destination?.symbol ?? "square",
                        description: Text("Здесь появится работа с сервисом после реализации и явного подключения аккаунта."))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Chat themes stay local to the selected service; window chrome stays Makosh.
        .tint(destination == .telegram ? resolvedTelegramAccent : WorkspaceStyle.accent)
        .environment(\.colorScheme, destination == .telegram ? resolvedTelegramScheme : .dark)
    }
    private var filteredContacts: [Contact] {
        if search.isEmpty { return model.contacts }
        return model.contacts.filter {
            [$0.displayName, $0.organization, $0.jobTitle, $0.emails.joined(separator: " "), $0.phones.joined(separator: " ")].joined(
                separator: " "
            ).localizedCaseInsensitiveContains(search)
        }
    }
    private func chooseImportFile() {
        guard let window = NSApp.keyWindow else {
            model.error = "Не удалось открыть диалог импорта. Сделайте окно Макоша активным и повторите."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Импорт контактов из JSON"
        panel.prompt = "Импортировать"
        panel.allowedContentTypes = [.json]
        // macOS 27 derives these flags when types change; set them afterwards.
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await model.importFile(url) }
        }
    }
}

private struct Avatar: View {
    let name: String
    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()).font(.system(size: 14, weight: .semibold))
            .frame(width: 40, height: 40).foregroundStyle(WorkspaceStyle.accent).background(
                WorkspaceStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct OtherCommunicationHosts: ViewModifier {
    let telegram: TelegramModel
    let mail: MailWorkspaceModel
    let whatsapp: WhatsAppWorkspaceModel
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.modifier(TelegramNotificationHost(controller: telegram.notifications)).modifier(MailNotificationHost(model: mail))
                .modifier(WhatsAppNotificationHost(model: whatsapp)).modifier(WhatsAppSettingsHost(model: whatsapp)).modifier(
                    WhatsAppCallHost(whatsapp.calls))
        } else {
            content
        }
    }
}

private struct TelemostGuardedTeamsHosts: ViewModifier {
    let model: TeamsWorkspaceModel
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.modifier(TeamsNotificationHost(model: model)).modifier(TeamsSettingsHost(model: model)) } else { content }
    }
}

private struct WhatsAppQAHosts: ViewModifier {
    let model: WhatsAppWorkspaceModel, enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.modifier(WhatsAppSettingsHost(model: model)).modifier(WhatsAppCallHost(model.calls)) } else { content }
    }
}
