import SwiftUI
import MakoshTeams

struct TeamsSidebarView: View {
    @ObservedObject var model: TeamsWorkspaceModel
    @State private var adding = false
    @State private var signingIn = false
    @State private var expandedTeams = Set<String>()
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label("Teams", systemImage: "person.3.fill").font(.title2.bold()); Spacer(); Button { adding = true } label: { Image(systemName: "plus") }.help("Добавить аккаунт").disabled(model.isSynthetic).accessibilityIdentifier("teams.account.add") }
                Picker("Аккаунт", selection: Binding(get: { model.selectedAccountID }, set: { id in if let id { Task { await model.selectAccount(id) } } })) {
                    Text("Выберите аккаунт").tag(Optional<UUID>.none)
                    ForEach(model.accounts) { Text($0.name).tag(Optional($0.id)) }
                }.pickerStyle(.menu).accessibilityIdentifier("teams.account.picker")
                HStack {
                    Text(teamsStateTitle(model.snapshot?.state, synthetic: model.isSynthetic)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Войти / предоставить разрешения") { signingIn = true }.disabled(model.isSynthetic || model.selectedAccountID == nil)
                        Button("Подключиться") { Task { await model.connect() } }.disabled(model.isSynthetic || model.selectedAccountID == nil)
                        Button("Отключиться") { Task { await model.disconnect() } }.disabled(model.selectedAccountID == nil)
                        Button("Обновить переписку") { Task { await model.synchronize() } }.disabled(model.snapshot?.state != .connected && model.snapshot?.state != .synthetic)
                        SettingsLink { Text("Настройки Teams…") }
                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).help("Подключение и настройки").accessibilityLabel("Подключение и настройки Teams")
                }
                if model.isSynthetic { Label("Синтетические данные", systemImage: "testtube.2").font(.caption).foregroundStyle(.orange) }
            }.padding(16)
            Divider()
            if model.accounts.isEmpty {
                ContentUnavailableView("Подключите Teams", systemImage: "person.3", description: Text("Рабочий или учебный аккаунт Microsoft 365. Нужна ваша регистрация приложения Entra."))
            } else {
                List(selection: Binding(get: { model.selectedScope }, set: { scope in if let scope { Task { await model.selectConversation(scope) } } })) {
                    Section("Чаты") {
                        ForEach(model.chats) { chat in
                            HStack { Label(chat.displayName, systemImage: chat.kind == .oneOnOne ? "person.crop.circle" : "person.2").lineLimit(1); Spacer(); if let count = model.unread[chat.scope], count > 0 { Text(String(count)).font(.caption).foregroundStyle(.secondary) } }.tag(chat.scope).padding(.vertical, 5).accessibilityIdentifier("teams.chat." + chat.id.base64EncodedString())
                        }
                    }
                    if let snapshot = model.snapshot, let principal = snapshot.principal {
                        Section("Команды и каналы") {
                            ForEach(snapshot.teams) { team in
                                DisclosureGroup(team.displayName, isExpanded: Binding(get: { expandedTeams.contains(team.id) }, set: { expanded in if expanded { expandedTeams.insert(team.id) } else { expandedTeams.remove(team.id) } })) {
                                    ForEach(snapshot.channels.filter { $0.teamID == team.id }) { channel in
                                        let scope = TeamsScope(accountID: snapshot.accountID, tenantID: principal.tenantID, resource: .channel(teamID: team.id, channelID: channel.id))
                                        Label(channel.displayName, systemImage: "number").lineLimit(1).tag(scope).accessibilityIdentifier("teams.channel." + channel.id)
                                    }
                                }
                            }
                        }
                    }
                }.listStyle(.sidebar).accessibilityIdentifier("teams.conversations")
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).padding(12).textSelection(.enabled) }
        }
        .onChange(of: model.selectedAccountID) { _, _ in expandedTeams.removeAll() }
        .sheet(isPresented: $adding) { TeamsConnectionView(model: model, creating: true) }
        .sheet(isPresented: $signingIn) { TeamsConnectionView(model: model, creating: false) }
    }
}

struct TeamsDetailView: View {
    @ObservedObject var model: TeamsWorkspaceModel
    var dossier: (TeamsPerson, TeamsScope) -> Void
    @State private var settings = false
    @State private var archive = false
    @State private var outbox = false
    @State private var preview: TeamsFileLease?
    @State private var previewName = "Вложение Teams"
    var body: some View {
        if let scope = model.selectedScope {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if scope != scope.policyScope { Button { Task { await model.openParentChannel() } } label: { Image(systemName: "chevron.left") }.help("Вернуться в канал") }
                    VStack(alignment: .leading, spacing: 3) { Text(model.title).font(.title3.bold()); Text(scope != scope.policyScope ? "Ветка обсуждения" : "Переписка Teams").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { Task { await model.markLocallyRead() } } label: { Image(systemName: "checkmark.circle") }.help("Отметить прочитанным в Макоше")
                    Button { archive = true } label: { Image(systemName: "clock.arrow.circlepath") }.help("История и версии").accessibilityIdentifier("teams.history.open")
                    Button { outbox = true } label: { Image(systemName: "tray.and.arrow.up") }.help("Исходящие").accessibilityIdentifier("teams.outbox.open")
                    Button { settings = true } label: { Image(systemName: "info.circle") }.help("Информация и настройки беседы").accessibilityIdentifier("teams.chat.settings")
                }.padding(16)
                HStack { TextField("Поиск в сохранённой переписке", text: $model.searchQuery).textFieldStyle(.roundedBorder).onSubmit { Task { await model.search() } }.accessibilityIdentifier("teams.search"); Button("Найти") { Task { await model.search() } }.disabled(model.historyBusy) }.padding(.horizontal, 16).padding(.bottom, 12)
                if model.historyExtended { Button("К новым сообщениям") { Task { await model.showLatest() } }.font(.caption).padding(8).accessibilityIdentifier("teams.history.latest") }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.hasOlder { Button("Загрузить ещё") { Task { await model.loadHistory(reset: false) } }.disabled(model.historyBusy).accessibilityIdentifier("teams.history.more") }
                        ForEach(model.rows.reversed()) { row in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    if let author = row.message.author { Button(author.displayName.isEmpty ? "Собеседник" : author.displayName) { dossier(author, scope) }.buttonStyle(.plain).font(.callout.bold()).disabled(author.tenantID.isEmpty).help("Связать человека с досье") }
                                    else { Text("Teams").font(.callout.bold()) }
                                    Spacer(); if let date = row.message.createdAt { Text(date, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                                }
                                if row.message.deletedAt != nil { Label("Удалено на сервере · версии сохранены", systemImage: "archivebox").foregroundStyle(.secondary) }
                                if !row.text.isEmpty { Text(row.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                ForEach(Array(row.message.attachments.enumerated()), id: \.offset) { _, attachment in
                                    HStack { Label(attachment.name ?? "Вложение", systemImage: "paperclip").lineLimit(2); Spacer(); Button("Открыть") { openFile(scope: scope, row: row, attachment: attachment) }.accessibilityIdentifier("teams.file.open." + attachment.id) }
                                }
                                if case .channel = scope.resource { Button("Открыть обсуждение") { Task { await model.openThread(row.message) } }.font(.caption).accessibilityIdentifier("teams.thread." + row.message.id) }
                            }.padding(14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12)).id(row.id)
                        }
                        if model.rows.isEmpty, !model.historyBusy { ContentUnavailableView("Сохранённых сообщений пока нет", systemImage: "text.bubble", description: Text("Подключите аккаунт и дождитесь синхронизации.")) }
                        if model.historyBusy { ProgressView().frame(maxWidth: .infinity) }
                    }.padding(16)
                }.defaultScrollAnchor(.bottom).accessibilityIdentifier("teams.messages")
                Divider()
                TeamsComposeView(model: model, composer: model.composer)
            }
            .sheet(isPresented: $settings) { TeamsChatSettingsView(model: model, scope: scope) { person in dossier(person, scope) } }
            .sheet(isPresented: $archive) { TeamsHistoryView(worker: model.worker, scope: scope, title: model.title) }
            .sheet(isPresented: $outbox) { TeamsOutboxView(model: model.composer) }
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { let old = preview; preview = nil; Task { await old?.release() } } })) { if let preview { TeamsFilePreview(lease: preview, name: previewName) } }
        } else {
            ContentUnavailableView("Выберите чат или канал Teams", systemImage: "person.3.sequence", description: Text("Аккаунты, переписка, файлы и досье — в общем рабочем пространстве."))
        }
    }
    private func openFile(scope: TeamsScope, row: TeamsMessageRow, attachment: TeamsAttachment) {
        Task {
            do {
                let lease = try await model.worker.download(scope: scope, messageID: row.message.id, attachmentID: attachment.id, version: String(row.id))
                guard model.selectedScope == scope, !Task.isCancelled else { await lease.release(); return }
                previewName = attachment.name ?? "Вложение Teams"
                preview = lease
            } catch { if model.selectedScope == scope { model.error = teamsFailureMessage(error) } }
        }
    }
}

func teamsStateTitle(_ state: TeamsConnectionState?, synthetic: Bool) -> String {
    if synthetic { return "QA · Microsoft не подключён" }
    switch state { case .connected: return "Подключено"; case .connecting: return "Подключение…"; case .signInRequired: return "Нужен вход"; case .failed: return "Ошибка подключения"; case .synthetic: return "Синтетическая проверка"; default: return "Не подключено" }
}
