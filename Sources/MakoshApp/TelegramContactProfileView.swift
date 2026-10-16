import SwiftUI
import MakoshCore
import MakoshTelegram

struct TelegramContactProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: TelegramModel
    @ObservedObject private var peerStatus: TelegramPeerStatusController
    @ObservedObject private var management: TelegramPeerManagementController
    @ObservedObject private var membership: TelegramGroupMembershipController
    let dossier: WorkspaceModel?
    let contextID: UUID
    let openDossier: (UUID) -> Void
    private enum Page { case overview, edit, members, media, permissions, groupInvite, groupLinks, groupRequests, groupHistory, secretCreation }
    @State private var page = Page.overview
    @State private var photoGallery: TelegramProfilePhotosPresentation?

    init(model: TelegramModel, dossier: WorkspaceModel?, contextID: UUID, openDossier: @escaping (UUID) -> Void) {
        self.model = model; self.peerStatus = model.peerStatus; self.management = model.peerManagement
        self.membership = model.groupMembership
        self.dossier = dossier; self.contextID = contextID; self.openDossier = openDossier
    }

    private var groupMode: TelegramGroupViewMode? {
        switch page { case .groupInvite: .invite; case .groupLinks: .links; case .groupRequests: .requests; case .groupHistory: .history; default: nil }
    }
    private var pageTitle: String {
        switch page {
        case .overview: "Информация"
        case .edit: "Редактирование"
        case .members: "Участники"
        case .media: "Общие медиа"
        case .permissions: "Разрешения"
        case .groupInvite: "Добавить участника"
        case .groupLinks: "Пригласительные ссылки"
        case .groupRequests: "Заявки на вступление"
        case .groupHistory: "Недавние действия"
        case .secretCreation: "Секретный чат"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if page != .overview {
                    Button("Назад") {
                        if page == .secretCreation { model.secretChats.closeCreation() }
                        if groupMode != nil { _ = membership.show(.overview) }; page = .overview
                    }
                        .disabled(management.mutationStatus == .saving || membership.isBusy)
                        .accessibilityIdentifier("telegram.profile.back")
                }
                Text(pageTitle).font(.headline)
                Spacer()
                if page != .overview && page != .media && page != .secretCreation {
                    Button("Обновить") { if groupMode != nil { membership.refresh() } else { management.refresh() } }
                        .disabled(management.mutationStatus == .saving || membership.isBusy)
                        .accessibilityIdentifier("telegram.profile.management.refresh")
                }
                if page == .overview, management.snapshot?.canEditInfo == true {
                    Button("Изменить") { page = .edit }.accessibilityIdentifier("telegram.profile.edit")
                }
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
                let current = management.snapshot.flatMap { $0.accountID == profile.accountID && $0.peerID == profile.peerID ? $0 : nil }
                let displayName = current?.title ?? profile.displayName
                let displayAbout = profile.isScam || profile.isFake ? nil : (current.map(\.about) ?? profile.about)
                if let groupMode {
                    TelegramGroupMembershipView(controller: membership, search: model.groupMemberSearch, mode: groupMode) { peer, searchContext, basis, groupContext in
                        model.inviteGroupMember(peer, searchContextID: searchContext, basis: basis, contextID: groupContext)
                    }
                }
                else if page == .secretCreation { TelegramSecretCreationView(controller: model.secretChats, synthetic: model.isSyntheticPreview) }
                else if page == .permissions { TelegramPeerPermissionsView(controller: management) }
                else if page == .edit { TelegramPeerInfoEditor(controller: management, avatarEditing: model.avatarEditing, avatarTarget: model.avatarTarget(profile, contextID: contextID)) }
                else if page == .members { TelegramPeerMembersView(controller: management, avatars: model.avatars) }
                else if page == .media {
                    TelegramSharedMediaView(model: model, profileContextID: contextID) { dismiss() }
                } else {
                Form {
                    Section {
                        VStack(spacing: 10) {
                            Button {
                                if model.openProfilePhotos(profile, contextID: contextID) {
                                    photoGallery = TelegramProfilePhotosPresentation(title: displayName)
                                }
                            } label: {
                                TelegramChatAvatar(title: displayName, peerID: profile.peerID, store: model.avatars, size: 72)
                            }.buttonStyle(.plain).help("Открыть фотографии профиля")
                                .accessibilityLabel("Фотографии профиля").accessibilityIdentifier("telegram.profile.photos")
                                .background {
                                    TelegramProfilePhotosPresenter(presentation: photoGallery, gallery: model.profilePhotos) { id in
                                        if photoGallery?.id == id { photoGallery = nil }
                                    }
                                }
                            Text(displayName.isEmpty ? "Имя не опубликовано" : displayName)
                                .font(.title2.weight(.semibold)).textSelection(.enabled)
                            Text(profile.kind.profileTitle).foregroundStyle(.secondary)
                                .accessibilityIdentifier("telegram.profile.kind")
                            if profile.isPerson, let status = peerStatus.status,
                               status.peerID == profile.peerID, status.accountID == profile.accountID, !status.isSelf {
                                TelegramPeerStatusView(status: status, identifier: "telegram.peerStatus.profile")
                            }
                            if profile.isScam || profile.isFake {
                                Label(profile.isScam ? "Пометка Telegram: мошенничество" : "Пометка Telegram: поддельный аккаунт",
                                    systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                                    .accessibilityIdentifier("telegram.profile.warning")
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    Section {
                        if profile.isPerson || profile.isBot {
                            if let phone = profile.phone, !phone.isEmpty {
                                LabeledContent("Телефон") { Text(phone).textSelection(.enabled) }
                            } else { LabeledContent("Телефон", value: "Недоступен") }
                        } else {
                            LabeledContent(profile.kind == .channel ? "Подписчики" : "Участники",
                                value: profile.memberCount.map { $0.formatted() } ?? "Недоступно")
                                .accessibilityIdentifier("telegram.profile.memberCount")
                        }
                        if let username = profile.username, !username.isEmpty {
                            LabeledContent("Имя пользователя") { Text("@" + username).textSelection(.enabled) }
                        }
                    }
                    if let about = displayAbout, !about.isEmpty {
                        Section {
                            Text(about).textSelection(.enabled).accessibilityIdentifier("telegram.profile.about")
                        } header: { Text("Описание") }
                    }
                    Section {
                        if profile.isPerson && profile.peerID != profile.accountID {
                            Button("Начать секретный чат") {
                                if model.openSecretChatCreation(profile, contextID: contextID) { page = .secretCreation }
                            }.accessibilityIdentifier("telegram.profile.startSecretChat")
                        }
                        TelegramNotificationPeerButton(controller: model.notifications, peerID: profile.peerID, title: displayName,
                            isCurrent: { model.messageActionContextID == contextID && model.notifications.accountID == profile.accountID })
                        Button("Общие медиа") {
                            if model.openSharedMedia(profile, contextID: contextID) { page = .media }
                        }.accessibilityIdentifier("telegram.profile.sharedMedia")
                        if management.snapshot?.canViewMembers == true {
                            Button("Участники") { management.show(.members); page = .members }
                                .accessibilityIdentifier("telegram.profile.members")
                        }
                        if membership.snapshot?.canInvite == true {
                            Button("Добавить участника") {
                                if model.openGroupMembership(profile, contextID: contextID, section: .overview) { page = .groupInvite }
                            }.accessibilityIdentifier("telegram.profile.addMember")
                        }
                        if membership.snapshot?.canManageLinks == true {
                            Button("Пригласительные ссылки") {
                                if model.openGroupMembership(profile, contextID: contextID, section: .activeLinks) { page = .groupLinks }
                            }.accessibilityIdentifier("telegram.profile.inviteLinks")
                        }
                        if membership.snapshot?.canRequests == true {
                            Button("Заявки на вступление") {
                                if model.openGroupMembership(profile, contextID: contextID, section: .requests) { page = .groupRequests }
                            }.accessibilityIdentifier("telegram.profile.joinRequests")
                        }
                        if membership.snapshot?.canHistory == true {
                            Button("Недавние действия") {
                                if model.openGroupMembership(profile, contextID: contextID, section: .history) { page = .groupHistory }
                            }.accessibilityIdentifier("telegram.profile.adminHistory")
                        }
                        if !profile.isPerson && !profile.isBot && (membership.status == .failed || membership.status == .timedOut) {
                            Button("Обновить приглашения и заявки", action: membership.refresh)
                        }
                        if management.snapshot?.canViewAdministrators == true {
                            Button("Администраторы") { management.show(.administrators); page = .members }
                                .accessibilityIdentifier("telegram.profile.administrators")
                        }
                        if management.snapshot?.canRestrict == true, management.snapshot?.defaultBannedRights != nil {
                            Button("Разрешения участников") { page = .permissions }.accessibilityIdentifier("telegram.profile.permissions")
                        }
                        if management.status == .failed || management.status == .timedOut, !profile.isPerson, !profile.isBot {
                            Button("Обновить сведения об управлении", action: management.refresh)
                        }
                    }
                    if profile.isPerson || profile.isBot {
                        Section {
                            TelegramProfileBlockAction(model: model, controller: model.accountBlockedUsers, profile: profile, profileContextID: contextID)
                        }
                    }
                    Section {
                        if !profile.isPerson {
                            Text("Этот диалог не связывается с досье человека.").foregroundStyle(.secondary)
                                .accessibilityIdentifier("telegram.profile.notPerson")
                        } else if let dossier {
                            TelegramDossierLinkView(workspace: dossier, telegram: model, profile: profile,
                                contextID: contextID) { id in dismiss(); openDossier(id) }
                        } else {
                            Text("Досье доступно в рабочем пространстве с PostgreSQL.").foregroundStyle(.secondary)
                        }
                    } header: { Text("Досье Макоша") }
                    Section {
                        Text("Наблюдение кэша Telegram · \(profile.observedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Карточка обновляется при получении сведений от Telegram.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped)
                }
            }
        }.frame(width: page == .media || page == .members ? 620 : 480, height: 680)
            .onChange(of: model.selectedChatID) { _, _ in photoGallery = nil; page = .overview }
            .onChange(of: model.contactProfileContextID) { _, _ in photoGallery = nil; page = .overview }
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
    @State private var submitting = false

    private var owners: [Contact] { workspace.contacts.filter { $0.identities.contains(profile.dossierIdentity) } }
    private var candidates: [Contact] {
        workspace.contacts.filter { query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
            || $0.organization.localizedCaseInsensitiveContains(query) }
    }
    private var canLink: Bool {
        workspace.canWrite && !submitting && telegram.isCurrentContactProfile(profile, contextID: contextID)
            && profile.isPerson && !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        } else if !profile.isPerson {
            Text("Этот диалог не связывается с досье человека.").foregroundStyle(.secondary)
                .accessibilityIdentifier("telegram.profile.notPerson")
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
        submitting = true
        Task {
            defer { submitting = false }
            committedID = await workspace.linkTelegramProfile(profile, telegram: telegram, contextID: contextID, contactID: id)
        }
    }
}

private extension TelegramContactProfile.Kind {
    var profileTitle: String {
        switch self {
        case .person: "Пользователь"
        case .bot: "Бот"
        case .group: "Группа"
        case .supergroup: "Супергруппа"
        case .channel: "Канал"
        }
    }
}
