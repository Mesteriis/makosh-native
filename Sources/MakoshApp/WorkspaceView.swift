import SwiftUI
import AppKit
import MakoshCore
import MakoshTelegram
import MakoshMail
import MakoshWhatsApp
import MakoshTeams
import MakoshTelemost
import UniformTypeIdentifiers

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var contacts: [Contact] = []
    @Published var duplicates: [DuplicateCandidate] = []
    @Published var merges: [MergeRecord] = []
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { selectionRevision &+= 1 } }
    }
    @Published var error: String?
    @Published var notice: String?
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var writesBlocked = false
    private var selectionRevision: UInt64 = 0
    private let worker: ContactWorkspaceWorker
    private var archiveConfiguration: ContactWorkspaceConfiguration?
    @Published private(set) var archiveBackupContext: TelegramArchiveBackupContext?
    #if DEBUG
    private var pendingUploadQAConfigured = false
    #endif
    init(requireExplicitDatabaseConfiguration: Bool = false, syntheticSchemaPrefix: String = "qa_telegram_dossier_") {
        worker = ContactWorkspaceWorker(requireExplicitDatabaseConfiguration: requireExplicitDatabaseConfiguration, syntheticSchemaPrefix: syntheticSchemaPrefix)
    }
    init(worker: ContactWorkspaceWorker) { self.worker = worker }

    /// The view owns startup lifetime; constructing the conductor performs no IO.
    func load() async {
        guard !ready, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let opened = try await worker.open()
            archiveConfiguration = opened.configuration
            publish(opened.snapshot)
            ready = true
        } catch { self.error = error.localizedDescription }
    }
    var dossierWorker: ContactWorkspaceWorker { worker }
    var mailConfiguration: ContactWorkspaceConfiguration? { archiveConfiguration }
    var selected: Contact? { contacts.first { $0.id == selectedID } }
    var canWrite: Bool { ready && !busy && !writesBlocked }
    func configureArchive(_ archive: TelegramArchiveController, synthetic: Bool = false) {
        guard let configuration = archiveConfiguration else { return }
        let schema = configuration.archiveSchema ?? configuration.schema
        if !synthetic { archive.configure(connectionString: configuration.connectionString, schema: schema) }
        let args = CommandLine.arguments
        let support = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("Makosh",isDirectory: true)
        let storage: URL
        if let index = args.firstIndex(of: "--storage-config"), args.indices.contains(index+1), !args[index+1].hasPrefix("--") {
            storage = URL(fileURLWithPath: args[index+1])
        } else { storage = support.appendingPathComponent("s3.json") }
        if !synthetic {
            archive.files.configure(connectionString: configuration.connectionString,schema: schema,
                configurationFile: storage,spoolDirectory: support.appendingPathComponent("FileArchiveQueue",isDirectory: true))
        }
        if archiveBackupContext == nil {
            let keys: ArchiveBackupKeys
            #if DEBUG
            if synthetic {
                guard schema.hasPrefix("qa_telegram_dossier_") else { return }
                keys = .init(lookup: { _ in Data(repeating: 0x51, count: 32) }, install: { _, key in
                    guard key == Data(repeating: 0x51, count: 32) else { throw ArchiveBackupError.conflict }
                })
            } else { keys = .keychain }
            #else
            keys = .keychain
            #endif
            archiveBackupContext = .init(connectionString: configuration.connectionString, schema: schema,
                storageFile: storage, keys: keys, synthetic: synthetic)
        }
    }
    #if DEBUG
    func configurePendingUploadRecoveryQAIfRequested(_ telegram: TelegramModel) {
        let args = CommandLine.arguments
        guard args.contains("--telegram-pending-upload-qa"), !pendingUploadQAConfigured else { return }
        guard telegram.isSyntheticPreview, let configuration = archiveConfiguration,
              configuration.schema.hasPrefix("qa_telegram_dossier_"),
              let storageIndex = args.firstIndex(of: "--storage-config"), args.indices.contains(storageIndex + 1),
              !args[storageIndex + 1].hasPrefix("--"),
              let draftsIndex = args.firstIndex(of: "--telegram-drafts-synthetic-preview"), args.indices.contains(draftsIndex + 1),
              !args[draftsIndex + 1].hasPrefix("--") else {
            error = "Восстановление вложений в синтетической проверке требует явных конфигураций S3, отдельной схемы PostgreSQL и тестового Postbox."
            return
        }
        do {
            let directory = URL(fileURLWithPath: args[draftsIndex + 1], isDirectory: true)
            try telegram.configurePendingUploadRecoveryQA(connectionString: configuration.connectionString,
                schema: configuration.schema, configurationFile: URL(fileURLWithPath: args[storageIndex + 1]),
                spoolDirectory: directory.appendingPathComponent("PendingUploadArchiveQueue", isDirectory: true),
                albums: args.contains("--telegram-albums-qa"))
            pendingUploadQAConfigured = true
        } catch { self.error = "Не удалось подготовить отдельное хранилище восстановления синтетических вложений." }
    }
    #endif
    @discardableResult func reload() async -> Bool {
        guard ready, !busy else { return false }
        busy = true
        defer { busy = false }
        do { publish(try await worker.snapshot()); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func save(_ draft: ContactDraft, id: UUID?) async -> Bool {
        await perform(.save(draft: draft, id: id), selectResult: true) != nil
    }
    func linkTelegramProfile(_ profile: TelegramContactProfile, telegram: TelegramModel,
                             contextID: UUID, contactID: UUID?) async -> UUID? {
        guard telegram.isCurrentContactProfile(profile, contextID: contextID), profile.isPerson else {
            error = "Карточка собеседника изменилась. Откройте её заново."
            return nil
        }
        let result = await perform(.link(profile.dossierImport,
            source: ImportSource(service: profile.dossierIdentity.service, accountID: profile.dossierIdentity.accountID),
            fetchedAt: profile.observedAt, contactID: contactID))
        guard case .linked(let id) = result?.value else { return nil }
        return id
    }
    func linkMailSender(_ letter: MailLetter) async -> UUID? {
        guard MailAddress.isValid(letter.sender) else { return nil }
        let result = await perform(.link(letter.dossierContact, source: ImportSource(service: "mail", accountID: letter.key.accountID), fetchedAt: Date(), contactID: nil))
        guard case .linked(let id) = result?.value else { return nil }
        return id
    }
    func linkWhatsAppChat(_ chat:WhatsAppChat,accountID:UUID) async->UUID? {
        guard let contact=chat.dossierContact else{return nil}
        let result=await perform(.link(contact,source:ImportSource(service:"whatsapp",accountID:accountID.uuidString),fetchedAt:Date(),contactID:nil))
        guard case .linked(let id)=result?.value else{return nil};return id
    }
    func linkTeamsPerson(_ person: TeamsPerson, accountID: UUID) async -> UUID? {
        guard let contact = try? await BackgroundWork.run({ person.dossierContact }) else { error = "Для привязки нужен подтверждённый профиль человека и его организация Teams."; return nil }
        let result = await perform(.link(contact, source: ImportSource(service: "teams", accountID: accountID.uuidString), fetchedAt: Date(), contactID: nil))
        guard case let .linked(id) = result?.value else { return nil }; return id
    }
    func openTelemostDossier(_ telemost: TelemostWorkspaceModel, contactID: UUID, while isCurrent: @MainActor () -> Bool) async -> UUID? {
        let context = telemost.contextID
        guard isCurrent(), let id = await telemost.openDossier(contactID: contactID), isCurrent(), context == telemost.contextID,
              await selectContact(id, while: { isCurrent() && context == telemost.contextID }),
              isCurrent(), context == telemost.contextID else { return nil }
        return id
    }
    func openTeamsDossier(_ person: TeamsPerson, accountID: UUID, while isCurrent: @MainActor () -> Bool) async -> UUID? {
        guard isCurrent(), let id = await linkTeamsPerson(person, accountID: accountID), isCurrent(),
              await selectContact(id, while: isCurrent), isCurrent() else { return nil }
        return id
    }
    func selectContact(_ id: UUID, while isCurrent: @MainActor () -> Bool = { true }) async -> Bool {
        guard ready, !busy, isCurrent() else { return false }
        let revision = selectionRevision
        busy = true
        defer { busy = false }
        do {
            let snapshot = try await worker.snapshot()
            guard isCurrent() else { return false }
            let selectionUnchanged = revision == selectionRevision
            publish(snapshot)
            guard snapshot.contacts.contains(where: { $0.id == id }) else {
                throw StoreError.invalid("Досье изменилось. Откройте карточку собеседника заново.")
            }
            guard selectionUnchanged else { return false }
            selectedID = id
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func publish(_ snapshot: ContactWorkspaceSnapshot) {
        contacts = snapshot.contacts; duplicates = snapshot.duplicates; merges = snapshot.merges
        if let selectedID, !contacts.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    private func perform(_ command: ContactWorkspaceCommand, selectResult: Bool = false) async -> ContactWorkspaceWriteResult? {
        guard canWrite else { return nil }
        let revision = selectionRevision
        busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await worker.apply(command)
            let selectionUnchanged = revision == selectionRevision
            if let snapshot = result.snapshot { publish(snapshot) }
            else {
                writesBlocked = true
                error = "Изменения сохранены, но не удалось обновить отображение. Не повторяйте действие. Проверьте подключение к PostgreSQL и откройте приложение заново."
            }
            if selectResult, selectionUnchanged {
                switch result.value {
                case .saved(let id), .merged(let id): selectedID = id
                default: break
                }
            }
            return result
        } catch {
            if let failure = error as? ContactWorkspaceError, failure.blocksWrites { writesBlocked = true }
            self.error = error.localizedDescription
            return nil
        }
    }
    func addNote(_ text: String, contactID: UUID? = nil) async -> Bool {
        guard let id = contactID ?? selectedID else { return false }
        return await perform(.addNote(contactID: id, text: text)) != nil
    }
    func importFile(_ url: URL) async {
        guard let result = await perform(.importFile(url)), case .imported(let count) = result.value else { return }
        notice = "Импорт завершён: создано \(count.created), обновлено \(count.updated)."
    }
    func merge(_ candidate: DuplicateCandidate, survivor: UUID) async -> Bool {
        guard survivor == candidate.firstID || survivor == candidate.secondID else { return false }
        return await perform(.merge(survivorID: survivor,
            removedID: survivor == candidate.firstID ? candidate.secondID : candidate.firstID), selectResult: true) != nil
    }
    @discardableResult func undo(_ record: MergeRecord) async -> Bool { await perform(.undo(record.id)) != nil }
    func name(_ id: UUID) -> String { contacts.first { $0.id == id }?.displayName ?? "Контакт недоступен" }

}

private enum Destination: String, CaseIterable, Identifiable {
    case contacts = "Контакты", mail = "Почта", telegram = "Telegram", whatsapp = "WhatsApp", teams = "Teams", meetings = "Встречи"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .contacts: "person.2"; case .mail: "envelope"; case .telegram: "paperplane"; case .whatsapp: "message"; case .teams: "person.3"; case .meetings: "video" }
    }
}
private struct EditorSelection: Identifiable { let id = UUID(); let contact: Contact? }

struct WorkspaceView: View {
    @EnvironmentObject private var callWindows: TelegramCallWindows
    @StateObject private var systemAppearance = TelegramSystemAppearance()
    @AppStorage(TelegramAppearancePreferences.preferenceKey) private var appearanceRaw = ""
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(TelegramLocalTheme.preferenceKey) private var telegramTheme = TelegramLocalTheme.system.rawValue
    @AppStorage(TelegramAccent.preferenceKey) private var telegramAccent = TelegramAccent.blue.rawValue
    @StateObject private var model: WorkspaceModel
    @StateObject private var mail: MailWorkspaceModel
    @StateObject private var telegram: TelegramModel
    private var isolatedWhatsApp=false
    @StateObject private var whatsapp = WhatsAppWorkspaceModel()
    @StateObject private var teams = TeamsWorkspaceModel()
    @StateObject private var telemost = TelemostWorkspaceModel()
    @State private var telemostDossierRequest = UUID()
    @State private var destination: Destination? = .contacts
    @State private var teamsDossierRequest = UUID()
    private var telegramAppearance: TelegramAppearancePreferences { (try? .decode(appearanceRaw)) ?? .init() }
    private var resolvedTelegramScheme: ColorScheme { telegramWorkspaceScheme(theme:telegramTheme,telegramSelected:true,system:systemAppearance.scheme,night:telegramAppearance.night,date:systemAppearance.now,cloudDark:telegramAppearance.cloudPalette?.isDark) }
    private var resolvedTelegramAccent: Color { telegramAppearance.effectivePalette(isDark:resolvedTelegramScheme == .dark).map { telegramPaletteColor($0,"accent",$0.accent) } ?? TelegramAccent(preference:telegramAccent).color }
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
        isolatedWhatsApp=true
        _model = StateObject(wrappedValue: WorkspaceModel(requireExplicitDatabaseConfiguration: true, syntheticSchemaPrefix: "qa_whatsapp_"))
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
    private var accent: Color {
        Color(red: 0.60, green: 0.38, blue: 0.96)
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.hexagongrid.fill").font(.title).foregroundStyle(accent)
                    VStack(alignment: .leading) { Text("Макош").font(.title2.bold()); Text("Личное рабочее пространство").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 16).padding(.top, 20)
                List(Destination.allCases.filter {!isolatedWhatsApp || $0 == .contacts || $0 == .whatsapp}, selection: $destination) { item in
                    Label(item.rawValue, systemImage: item.symbol).padding(.vertical, 5).tag(item)
                }.listStyle(.sidebar).accessibilityIdentifier("workspace.sidebar")
                    .frame(maxHeight: destination == .mail ? 290 : .infinity)
                if destination == .mail { MailFoldersView(model: mail).disabled(mail.busy) }
                VStack(alignment: .leading, spacing: 6) {
                    Label("Локальный PostgreSQL", systemImage: "externaldrive.connected.to.line.below").font(.callout.weight(.medium))
                    Text("Досье и переписка рядом. Файлы — в S3.").font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }.background { WorkspaceBackdrop(intensity: 0.55) }.navigationSplitViewColumnWidth(min: destination == .mail ? 250 : 220, ideal: destination == .mail ? 290 : 250, max: destination == .mail ? 360 : 310)
        } content: {
            if destination == .contacts {
                VStack(spacing: 0) {
                    HStack { VStack(alignment: .leading, spacing: 4) { Text("Контакты").font(.title2.bold()); Text("\(model.contacts.count) в вашей картотеке").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { editor = EditorSelection(contact: nil) } label: { Image(systemName: "plus") }.help("Новый контакт").accessibilityIdentifier("contacts.create").disabled(!model.canWrite) }.padding(20)
                    TextField("Поиск по имени, компании, почте", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 12).accessibilityIdentifier("contacts.search")
                    Divider()
                    if model.contacts.isEmpty {
                        ContentUnavailableView("Пока нет контактов", systemImage: "person.crop.rectangle.stack", description: Text("Создайте контакт или импортируйте JSON-файл.")).frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                    } else {
                        List(selection: $model.selectedID) {
                            ForEach(filteredContacts) { contact in
                                HStack(spacing: 12) {
                                    Avatar(name: contact.displayName)
                                    VStack(alignment: .leading, spacing: 4) { Text(contact.displayName).font(.headline); Text(contact.organization.isEmpty ? (contact.emails.first ?? "Личный контакт") : contact.organization).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }.padding(.vertical, 8).tag(contact.id).accessibilityIdentifier("contact.row.\(contact.id)")
                            }
                        }.listStyle(.inset)
                    }
                    Divider()
                    VStack(spacing: 10) {
                        Button(action: chooseImportFile) { Label("Импортировать JSON", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }.accessibilityIdentifier("contacts.import").disabled(!model.canWrite)
                        Button { review = true } label: { Label("Объединения · \(model.duplicates.count)", systemImage: "person.2.badge.gearshape").frame(maxWidth: .infinity) }.accessibilityIdentifier("contacts.duplicates").disabled(!model.canWrite)
                    }.padding(16)
                }.frame(maxHeight: .infinity, alignment: .top).navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 390)
            } else if destination == .mail {
                MailMessageListView(model: mail).navigationSplitViewColumnWidth(min: 340, ideal: 390, max: 560)
            } else if destination == .telegram {
                TelegramSidebarView(model: telegram, backupContext: model.archiveBackupContext).navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 390)
            } else if destination == .teams {
                TeamsSidebarView(model: teams).navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 440)
            } else if destination == .meetings {
                TelemostCatalogueView(model: telemost).navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 440)
            } else if destination == .whatsapp {
                WhatsAppSidebarView(model: whatsapp).navigationSplitViewColumnWidth(min: 300, ideal: 350, max: 440)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Label(destination?.rawValue ?? "", systemImage: destination?.symbol ?? "square").font(.title2.bold())
                    Label("Не подключено", systemImage: "circle.dashed").foregroundStyle(.secondary)
                    Text(destination == .meetings ? "Откройте встречу в Яндекс Телемосте по своей ссылке." : "Подключение сервиса ещё не реализовано. Ваши аккаунты не запрашиваются.").foregroundStyle(.secondary)
                    Spacer()
                }.padding(24).navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 390)
            }
        } detail: {
            VStack(spacing: 0) {
                TelegramCallCompactView(controller: telegram.calls)
                Group {
                    if destination == .contacts {
                        if let contact = model.selected { DossierView(contact: contact, model: model, openMeeting: telemost.openMeeting) { editor = EditorSelection(contact: contact) } }
                        else { ContentUnavailableView("Всё о человеке — рядом", systemImage: "person.text.rectangle", description: Text("Выберите контакт, чтобы открыть досье, заметки и источники.")) }
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
                        TelegramDetailView(model: telegram, dossier: model) { id in
                            Task { if await model.selectContact(id) { destination = .contacts } }
                        }
                    }
                    else if destination == .whatsapp { WhatsAppDetailView(model: whatsapp,dossier:{
                        guard let account=whatsapp.selectedAccountID,let chat=whatsapp.selectedChat else{return}
                        Task{if let id=await model.linkWhatsAppChat(chat,accountID:account),whatsapp.selectedAccountID==account,whatsapp.selectedChatID==chat.id,await model.selectContact(id){destination = .contacts}}
                    }).id((whatsapp.selectedAccountID?.uuidString ?? "")+":"+(whatsapp.selectedChatID ?? "")) }
                    else if destination == .teams {
                        TeamsDetailView(model: teams) { person, scope in
                            let request = UUID(); teamsDossierRequest = request
                            Task {
                                let id = await model.openTeamsDossier(person, accountID: scope.accountID, while: {
                                    teamsDossierRequest == request && destination == .teams && teams.selectedScope == scope
                                })
                                if id != nil { destination = .contacts }
                            }
                        }.id(teams.selectedScope?.storageKey.base64EncodedString() ?? "teams-empty")
                    }
                    else if destination == .meetings {
                        TelemostDetailView(model: telemost, contacts: model.contacts) { contact in
                            let request = UUID(), window = NSApp.keyWindow
                            telemostDossierRequest = request
                            Task {
                                let id = await model.openTelemostDossier(telemost, contactID: contact, while: {
                                    telemostDossierRequest == request && destination == .meetings && window != nil &&
                                    window === NSApp.keyWindow && window?.isVisible == true && window?.isMiniaturized == false
                                })
                                if id != nil { destination = .contacts }
                            }
                        }
                    }
                    else { ContentUnavailableView("\(destination?.rawValue ?? "Сервис") не подключён", systemImage: destination?.symbol ?? "square", description: Text("Здесь появится работа с сервисом после реализации и явного подключения аккаунта.")) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if !isolatedWhatsApp && !teams.isSynthetic && !telemost.isSynthetic { callWindows.register(telegram.calls, synthetic: telegram.isSyntheticPreview, avatars: telegram.avatars) } }
        .onDisappear { callWindows.unregister(telegram.calls);Task{await whatsapp.calls.end()} }
        .tint(destination == .telegram ? resolvedTelegramAccent : accent)
        .accentColor(destination == .telegram ? resolvedTelegramAccent : accent)
        .preferredColorScheme(telegramWorkspaceScheme(theme: telegramTheme, telegramSelected: destination == .telegram, system: systemAppearance.scheme, night: ((try? TelegramAppearancePreferences.decode(appearanceRaw)) ?? .init()).night, date: systemAppearance.now, cloudDark: telegramAppearance.cloudPalette?.isDark))
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbarColorScheme(destination == .telegram ? nil : .dark, for: .windowToolbar)
        .modifier(OtherCommunicationHosts(telegram: telegram, mail: mail, whatsapp: whatsapp, enabled: !isolatedWhatsApp && !teams.isSynthetic && !telemost.isSynthetic))
        .modifier(TelemostGuardedTeamsHosts(model: teams, enabled: !isolatedWhatsApp && !telemost.isSynthetic))
        .modifier(WhatsAppQAHosts(model:whatsapp,enabled:isolatedWhatsApp))
        .onReceive(telegram.notifications.$activationRequest.dropFirst()) { _ in destination = .telegram }
        .onReceive(whatsapp.$notificationActivation.dropFirst()){_ in destination = .whatsapp}
        .onReceive(mail.$notificationActivation.dropFirst()) { _ in destination = .mail }
        .onReceive(teams.$notificationActivation.dropFirst()) { _ in destination = .teams }
        .task {
            await model.load()
            if let configuration = model.mailConfiguration {
                if !whatsapp.isSynthetic && !teams.isSynthetic && !telemost.isSynthetic { await mail.load(configuration: configuration) }
                if destination == .whatsapp && !teams.isSynthetic && !telemost.isSynthetic { await whatsapp.load(configuration: configuration) }
                if destination == .teams && !isolatedWhatsApp && !telemost.isSynthetic { await teams.load(configuration: configuration) }
                if destination == .meetings && !isolatedWhatsApp { await telemost.start(configuration: configuration) }
            }
        }
        .onChange(of: teams.selectedScope) { _, _ in teamsDossierRequest = UUID() }
        .onChange(of: destination) { _, selected in
            teamsDossierRequest = UUID(); telemostDossierRequest = UUID()
            if selected == .meetings, !mail.synthetic, !whatsapp.isSynthetic, !teams.isSynthetic, let configuration = model.mailConfiguration { Task { await telemost.start(configuration: configuration) } }
            if selected == .teams, !isolatedWhatsApp, !telemost.isSynthetic, let configuration = model.mailConfiguration { Task { await teams.load(configuration: configuration) } }
            if selected == .whatsapp, !teams.isSynthetic, !telemost.isSynthetic, let configuration = model.mailConfiguration { Task { await whatsapp.load(configuration: configuration) } }
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
        .sheet(item: $editor) { selection in ContactEditor(contact: selection.contact, model: model) }
        .sheet(isPresented: $review) { MergeReviewView(model: model) }
        .alert("Макош", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно", role: .cancel) { model.error = nil } } message: { Text(model.error ?? "") }
        .overlay(alignment: .bottomTrailing) {
            if let notice = model.notice { HStack { Text(notice); Button { model.notice = nil } label: { Image(systemName: "xmark") } }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(20) }
        }
        .frame(minWidth: destination == .mail ? 1220 : nil)
    }
    private var filteredContacts: [Contact] {
        if search.isEmpty { return model.contacts }
        return model.contacts.filter { [$0.displayName, $0.organization, $0.jobTitle, $0.emails.joined(separator: " "), $0.phones.joined(separator: " ")].joined(separator: " ").localizedCaseInsensitiveContains(search) }
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
    var body: some View { Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()).font(.system(size: 14, weight: .semibold)).frame(width: 40, height: 40).foregroundStyle(.indigo).background(.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)) }
}

private struct OtherCommunicationHosts: ViewModifier {
    let telegram: TelegramModel
    let mail: MailWorkspaceModel
    let whatsapp: WhatsAppWorkspaceModel
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.modifier(TelegramNotificationHost(controller: telegram.notifications)).modifier(MailNotificationHost(model: mail)).modifier(WhatsAppNotificationHost(model: whatsapp)).modifier(WhatsAppSettingsHost(model: whatsapp)).modifier(WhatsAppCallHost(whatsapp.calls)) }
        else { content }
    }
}

private struct TelemostGuardedTeamsHosts: ViewModifier {
    let model: TeamsWorkspaceModel
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.modifier(TeamsNotificationHost(model: model)).modifier(TeamsSettingsHost(model: model)) }
        else { content }
    }
}

private struct WhatsAppQAHosts:ViewModifier {
 let model:WhatsAppWorkspaceModel,enabled:Bool
 @ViewBuilder func body(content:Content)->some View {if enabled {content.modifier(WhatsAppSettingsHost(model:model)).modifier(WhatsAppCallHost(model.calls))}else {content}}
}
