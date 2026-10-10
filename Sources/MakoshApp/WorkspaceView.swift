import SwiftUI
import AppKit
import MakoshCore
import MakoshTelegram
import UniformTypeIdentifiers

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var contacts: [Contact] = []
    @Published var duplicates: [DuplicateCandidate] = []
    @Published var merges: [MergeRecord] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    @Published var notice: String?
    private var store: ContactStore?
    private var archiveConfiguration: DatabaseConfiguration?
    private struct DatabaseConfiguration: Decodable {
        let connectionString: String
        let schema: String
        private enum CodingKeys: String, CodingKey { case connectionString, schema }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            connectionString = try values.decode(String.self, forKey: .connectionString)
            schema = try values.decodeIfPresent(String.self, forKey: .schema) ?? "makosh"
        }
    }
    init(requireExplicitDatabaseConfiguration: Bool = false) {
        let setupMessage = "Не удалось открыть PostgreSQL. Запустите scripts/dev-db.sh up и scripts/run.sh. Проверьте файл конфигурации базы данных."
        do {
            let args = CommandLine.arguments
            let configURL: URL
            if let index = args.firstIndex(of: "--database-config") {
                guard args.indices.contains(index + 1), !args[index + 1].hasPrefix("--") else {
                    self.error = "После --database-config укажите путь к JSON-конфигурации базы. " + setupMessage
                    return
                }
                configURL = URL(fileURLWithPath: args[index + 1])
            } else {
                guard !requireExplicitDatabaseConfiguration else {
                    self.error = "Синтетическая проверка требует --database-config с отдельной тестовой схемой."
                    return
                }
                configURL = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                    .appendingPathComponent("Makosh/database.json")
            }
            let configuration = try JSONDecoder().decode(DatabaseConfiguration.self, from: Data(contentsOf: configURL))
            guard !requireExplicitDatabaseConfiguration || configuration.schema.hasPrefix("qa_telegram_dossier_") else {
                self.error = "Для этой проверки нужна отдельная схема qa_telegram_dossier_…"
                return
            }
            guard !configuration.connectionString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.error = setupMessage; return
            }
            store = try ContactStore(connectionString: configuration.connectionString, schema: configuration.schema)
            archiveConfiguration = configuration
            try reload()
        } catch {
            // Connection strings and decoding diagnostics may contain credentials.
            store = nil
            self.error = setupMessage
        }
    }
    var selected: Contact? { contacts.first { $0.id == selectedID } }
    var ready: Bool { store != nil }
    func configureArchive(_ archive: TelegramArchiveController) {
        guard let configuration = archiveConfiguration else { return }
        archive.configure(connectionString: configuration.connectionString, schema: configuration.schema)
        let args = CommandLine.arguments
        let support = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("Makosh",isDirectory: true)
        let storage: URL
        if let index = args.firstIndex(of: "--storage-config"), args.indices.contains(index+1), !args[index+1].hasPrefix("--") {
            storage = URL(fileURLWithPath: args[index+1])
        } else { storage = support.appendingPathComponent("s3.json") }
        archive.files.configure(connectionString: configuration.connectionString,schema: configuration.schema,
            configurationFile: storage,spoolDirectory: support.appendingPathComponent("FileArchiveQueue",isDirectory: true))
    }
    func reload() throws {
        guard let store else { throw StoreError.invalid("Хранилище не открыто. Перезапустите приложение после устранения ошибки.") }
        contacts = try store.contacts(); duplicates = try store.duplicateCandidates(); merges = try store.mergeHistory()
        if let selectedID, !contacts.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }
    func save(_ draft: ContactDraft, id: UUID?) -> Bool {
        perform {
            guard let store else { throw StoreError.invalid("Хранилище недоступно.") }
            if let id { try store.updateContact(id: id, draft: draft); selectedID = id }
            else { selectedID = try store.createContact(draft: draft) }
        }
    }
    func linkTelegramProfile(_ profile: TelegramContactProfile, telegram: TelegramModel,
                             contextID: UUID, contactID: UUID?) -> UUID? {
        guard telegram.isCurrentContactProfile(profile, contextID: contextID), !profile.isBot else {
            error = "Карточка собеседника изменилась. Откройте её заново."
            return nil
        }
        var linkedID: UUID?
        let committed = perform {
            guard let store else { throw StoreError.invalid("Хранилище недоступно.") }
            linkedID = try store.linkImportedContact(profile.dossierImport,
                source: ImportSource(service: profile.dossierIdentity.service, accountID: profile.dossierIdentity.accountID),
                fetchedAt: profile.observedAt, contactID: contactID)
        }
        return committed ? linkedID : nil
    }
    func selectContact(_ id: UUID) -> Bool {
        do {
            try reload()
            guard contacts.contains(where: { $0.id == id }) else {
                throw StoreError.invalid("Досье изменилось. Откройте карточку собеседника заново.")
            }
            selectedID = id
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult func perform(_ operation: () throws -> Void) -> Bool {
        do { try operation() }
        catch { self.error = error.localizedDescription; return false }
        // A returned write is known to have committed. Refresh failure must not
        // keep the editor/note open and invite repeating that successful write.
        // A thrown operation can still have an uncertain COMMIT outcome; do not retry it.
        do { try reload() }
        catch {
            self.error = "Изменения сохранены, но не удалось обновить отображение. Не повторяйте действие. Проверьте подключение к PostgreSQL и откройте приложение заново."
        }
        return true
    }
    func addNote(_ text: String) -> Bool {
        guard let store, let selectedID else { return false }
        return perform { try store.addNote(contactID: selectedID, text: text) }
    }
    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        perform {
            guard let store else { throw StoreError.invalid("Хранилище недоступно.") }
            let result = try store.importJSON(data: Data(contentsOf: url))
            notice = "Импорт завершён: создано \(result.created), обновлено \(result.updated)."
        }
    }
    func merge(_ candidate: DuplicateCandidate, survivor: UUID) -> Bool {
        guard let store else { return false }
        return perform {
            _ = try store.merge(survivorID: survivor, removedID: survivor == candidate.firstID ? candidate.secondID : candidate.firstID)
            selectedID = survivor
        }
    }
    func undo(_ record: MergeRecord) { guard let store else { return }; perform { try store.undoMerge(id: record.id) } }
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
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model: WorkspaceModel
    @StateObject private var telegram: TelegramModel
    @State private var destination: Destination? = .contacts
    @State private var search = ""
    @State private var editor: EditorSelection?
    @State private var review = false
    init() {
        _model = StateObject(wrappedValue: WorkspaceModel())
        _telegram = StateObject(wrappedValue: TelegramModel())
    }
    #if DEBUG
    init(syntheticTelegram: TelegramModel) {
        _model = StateObject(wrappedValue: WorkspaceModel(requireExplicitDatabaseConfiguration: true))
        _telegram = StateObject(wrappedValue: syntheticTelegram)
        _destination = State(initialValue: .telegram)
    }
    #endif
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.72, green: 0.68, blue: 0.98) : Color(red: 0.35, green: 0.32, blue: 0.72)
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "circle.hexagongrid.fill").font(.title).foregroundStyle(accent)
                    VStack(alignment: .leading) { Text("Макош").font(.title2.bold()); Text("Личное рабочее пространство").font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 16).padding(.top, 20)
                List(Destination.allCases, selection: $destination) { item in
                    Label(item.rawValue, systemImage: item.symbol).padding(.vertical, 5).tag(item)
                }.listStyle(.sidebar).accessibilityIdentifier("workspace.sidebar")
                VStack(alignment: .leading, spacing: 6) {
                    Label("Локальный PostgreSQL", systemImage: "externaldrive.connected.to.line.below").font(.callout.weight(.medium))
                    Text("Контакты в PostgreSQL; Telegram — отдельный сеанс.").font(.caption).foregroundStyle(.secondary)
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 250)
        } content: {
            if destination == .contacts {
                VStack(spacing: 0) {
                    HStack { VStack(alignment: .leading, spacing: 4) { Text("Контакты").font(.title2.bold()); Text("\(model.contacts.count) в вашей картотеке").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { editor = EditorSelection(contact: nil) } label: { Image(systemName: "plus") }.help("Новый контакт").accessibilityIdentifier("contacts.create").disabled(!model.ready) }.padding(20)
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
                        Button(action: chooseImportFile) { Label("Импортировать JSON", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }.accessibilityIdentifier("contacts.import").disabled(!model.ready)
                        Button { review = true } label: { Label("Объединения · \(model.duplicates.count)", systemImage: "person.2.badge.gearshape").frame(maxWidth: .infinity) }.accessibilityIdentifier("contacts.duplicates").disabled(!model.ready)
                    }.padding(16)
                }.frame(maxHeight: .infinity, alignment: .top).navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 390)
            } else if destination == .telegram {
                TelegramSidebarView(model: telegram).navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 390)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Label(destination?.rawValue ?? "", systemImage: destination?.symbol ?? "square").font(.title2.bold())
                    Label("Не подключено", systemImage: "circle.dashed").foregroundStyle(.secondary)
                    Text(destination == .meetings ? "Откройте встречу в Яндекс Телемосте по своей ссылке." : "Подключение сервиса ещё не реализовано. Ваши аккаунты не запрашиваются.").foregroundStyle(.secondary)
                    Spacer()
                }.padding(24).navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 390)
            }
        } detail: {
            if destination == .contacts {
                if let contact = model.selected { DossierView(contact: contact, model: model) { editor = EditorSelection(contact: contact) } }
                else { ContentUnavailableView("Всё о человеке — рядом", systemImage: "person.text.rectangle", description: Text("Выберите контакт, чтобы открыть досье, заметки и источники.")) }
            } else if destination == .telegram {
                TelegramDetailView(model: telegram, dossier: model) { id in
                    if model.selectContact(id) { destination = .contacts }
                }
            }
            else if destination == .meetings { MeetingsView() }
            else { ContentUnavailableView("\(destination?.rawValue ?? "Сервис") не подключён", systemImage: destination?.symbol ?? "square", description: Text("Здесь появится работа с сервисом после реализации и явного подключения аккаунта.")) }
        }
        .tint(accent).background(Color(nsColor: .windowBackgroundColor))
        .onAppear { if !telegram.isSyntheticPreview { model.configureArchive(telegram.archive) } }
        .sheet(item: $editor) { selection in ContactEditor(contact: selection.contact, model: model) }
        .sheet(isPresented: $review) { MergeReviewView(model: model) }
        .alert("Макош", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно", role: .cancel) { model.error = nil } } message: { Text(model.error ?? "") }
        .overlay(alignment: .bottomTrailing) {
            if let notice = model.notice { HStack { Text(notice); Button { model.notice = nil } label: { Image(systemName: "xmark") } }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(20) }
        }
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
            model.importFile(url)
        }
    }
}

private struct Avatar: View {
    let name: String
    var body: some View { Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()).font(.system(size: 14, weight: .semibold)).frame(width: 40, height: 40).foregroundStyle(.indigo).background(.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 12)) }
}
