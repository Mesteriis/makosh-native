import SwiftUI
import MakoshCore
import MakoshTelegram

struct TelegramContactProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: TelegramModel
    let dossier: WorkspaceModel?
    let contextID: UUID
    let openDossier: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Информация").font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("telegram.profile.close")
            }.padding(16)
            Divider()
            switch model.contactProfileState {
            case .idle:
                Text("Откройте карточку собеседника заново.").padding(24)
            case .loading:
                ProgressView("Загрузка карточки…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .unavailable(message):
                VStack(spacing: 16) {
                    Text(message).multilineTextAlignment(.center)
                    Button("Повторить", action: model.loadContactProfile)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .ready(profile):
                Form {
                    Section {
                        VStack(spacing: 10) {
                            TelegramChatAvatar(title: profile.displayName, size: 72)
                            Text(profile.displayName.isEmpty ? "Имя не опубликовано" : profile.displayName)
                                .font(.title2.weight(.semibold)).textSelection(.enabled)
                            if profile.isBot { Text("Бот").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    Section {
                        if let phone = profile.phone, !phone.isEmpty {
                            LabeledContent("Телефон") { Text(phone).textSelection(.enabled) }
                        } else { LabeledContent("Телефон", value: "Недоступен") }
                        if let username = profile.username, !username.isEmpty {
                            LabeledContent("Имя пользователя") { Text("@" + username).textSelection(.enabled) }
                        }
                    }
                    Section {
                        if let dossier {
                            TelegramDossierLinkView(workspace: dossier, telegram: model, profile: profile,
                                contextID: contextID) { id in dismiss(); openDossier(id) }
                        } else {
                            Text("Досье доступно в рабочем пространстве с PostgreSQL.").foregroundStyle(.secondary)
                        }
                    } header: { Text("Досье Макоша") }
                    Section {
                        Text("Сведения из локального кэша Telegram · \(profile.observedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
            }
        }.frame(width: 480, height: 620)
    }
}

private struct TelegramDossierLinkView: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var telegram: TelegramModel
    let profile: TelegramContactProfile
    let contextID: UUID
    let openDossier: (UUID) -> Void
    @State private var existing = false
    @State private var targetID: UUID?
    @State private var query = ""
    // A known committed write must never leave a repeatable create/link action
    // behind when refreshing the workspace fails after COMMIT.
    @State private var committedID: UUID?

    private var owners: [Contact] { workspace.contacts.filter { $0.identities.contains(profile.dossierIdentity) } }
    private var candidates: [Contact] {
        workspace.contacts.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
            || $0.organization.localizedCaseInsensitiveContains(query) }
    }
    private var canLink: Bool {
        workspace.ready && telegram.isCurrentContactProfile(profile, contextID: contextID)
            && !profile.isBot && !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!existing || workspace.contacts.contains { $0.id == targetID })
    }
    var body: some View {
        if !workspace.ready {
            Text("PostgreSQL недоступен. Проверьте подключение и откройте приложение заново.").foregroundStyle(.secondary)
        } else if owners.count > 1 {
            Text("Неоднозначная связь с досье. Привязка остановлена.").foregroundStyle(.red)
        } else if let id = committedID ?? owners.first?.id {
            Text(workspace.contacts.first { $0.id == id }?.displayName ?? "Досье связано")
                .font(.headline).accessibilityIdentifier("telegram.profile.linkedName")
            Button("Открыть досье") { openDossier(id) }
                .accessibilityIdentifier("telegram.profile.openDossier")
            if committedID == nil {
                Button("Обновить сведения из карточки") { link(to: id) }
                    .disabled(!canLink).accessibilityIdentifier("telegram.profile.refreshDossier")
            } else {
                Text("Источник связан с досье.").font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("telegram.profile.linked")
            }
        } else if profile.isBot {
            Text("Досье человека для бота не создаётся.").foregroundStyle(.secondary)
        } else if profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("В карточке нет имени. Привязка станет доступна после его появления в Telegram.").foregroundStyle(.secondary)
        } else {
            Picker("Связать с", selection: $existing) {
                Text("Новым досье").tag(false)
                Text("Существующим контактом").tag(true)
            }.accessibilityIdentifier("telegram.profile.linkMode")
                .onChange(of: existing) { _, _ in targetID = nil }
            if existing {
                TextField("Поиск контакта", text: $query).accessibilityIdentifier("telegram.profile.contactSearch")
                    .onChange(of: query) { _, _ in targetID = nil }
                Picker("Контакт", selection: $targetID) {
                    Text("Выберите контакт").tag(nil as UUID?)
                    ForEach(candidates) { contact in
                        Text(contact.organization.isEmpty ? contact.displayName : "\(contact.displayName) · \(contact.organization)")
                            .tag(Optional(contact.id))
                    }
                }.accessibilityIdentifier("telegram.profile.contactChoice")
            }
            Text("Имя и доступный телефон сохранятся с источником Telegram. Ручные правки останутся в досье.")
                .font(.caption).foregroundStyle(.secondary)
            Button(existing ? "Связать с контактом" : "Создать досье") { link(to: existing ? targetID : nil) }
                .disabled(!canLink).accessibilityIdentifier("telegram.profile.link")
        }
        if let error = workspace.error {
            Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("telegram.profile.linkError")
        }
    }
    private func link(to id: UUID?) {
        guard canLink else { return }
        committedID = workspace.linkTelegramProfile(profile, telegram: telegram, contextID: contextID, contactID: id)
    }
}
