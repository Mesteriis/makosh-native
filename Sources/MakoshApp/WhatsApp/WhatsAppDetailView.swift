import MakoshFiles
import MakoshWhatsApp
// Layout adapted from WhatsApp Zen MainView.swift / Components.swift (MIT).
// See LICENSES/WhatsApp-Zen-MIT.txt and docs/reference-interface.md.
import SwiftUI

struct WhatsAppDetailView: View {
    @ObservedObject var model: WhatsAppWorkspaceModel
    var dossier: () -> Void = {}
    private let sourceAccount: UUID?
    private let sourceChat: String?
    /// The bytes of a WhatsApp file message for Paperless, a chat, a letter or the AI.
    private static func fileHandoff(_ message: WhatsAppMessage, model: WhatsAppWorkspaceModel, account: UUID) -> FileHandoff {
        FileHandoff(
            name: message.details?.name ?? "file", byteCount: message.details?.size.map(Int64.init),
            date: Date(timeIntervalSince1970: TimeInterval(message.timestamp))
        ) { url in
            guard let lease = await model.actions.download(message, expectedAccount: account) else { throw WhatsAppFailure.unavailable }
            defer { lease.remove() }
            try FileManager.default.copyItem(at: lease.url, to: url)
        }
    }

    init(model: WhatsAppWorkspaceModel, dossier: @escaping () -> Void = {}) {
        self.model = model
        self.dossier = dossier
        sourceAccount = model.selectedAccountID
        sourceChat = model.selectedChatID
        _history = StateObject(
            wrappedValue: .init(
                worker: model.notificationWorker, accountID: model.selectedAccountID ?? UUID(),
                chat: model.selectedChatID ?? ""))
    }
    @State private var richCompose = false
    @State private var callDevices = false
    @State private var settings = false
    @State private var showInfo = true
    @State private var showSearch = false
    @State private var historyFilter = WhatsAppHistoryFilter.all
    @State private var peerInfo: WhatsAppPeerInfo?
    @StateObject private var history: WhatsAppHistoryModel
    @State private var archive = false
    @State private var archivedMessage: String?
    @State private var actionMessage: WhatsAppMessage?
    @State private var actionKind = ""
    @State private var actionText = ""
    private struct GroupRequest: Identifiable {
        let id = UUID()
        let account: UUID, chat: String, video: Bool
    }
    @State private var groupRequest: GroupRequest?
    @State private var preview: WhatsAppFileLease?
    var body: some View {
        Group {
            if ["qr", "connecting", "expired"].contains(model.status.state) {
                WhatsAppPairingView(model: model)
            } else if let chat = model.selectedChat {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        HStack(spacing: 12) {
                            WhatsAppAvatarView(
                                name: chat.name, group: chat.group,
                                scope: model.selectedAccountID.map { .init(accountID: $0, jid: chat.id) },
                                revision: model.status.avatarRevisions?[chat.id] ?? 0, epoch: model.status.avatarEpoch ?? 0,
                                worker: model.notificationWorker, cache: model.avatarCache)
                            VStack(alignment: .leading) {
                                Text(chat.name).font(.title3.bold())
                                Text(
                                    chat.group
                                        ? (peerInfo?.members.map { "\($0.count) участников" } ?? "Групповой чат") : model.status.label
                                )
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                startCall(video: false, chat: chat)
                            } label: {
                                Image(systemName: "phone")
                            }.help("Аудиозвонок").disabled(
                                model.isSynthetic || !model.status.linked || model.calls.call != nil)
                            Button {
                                startCall(video: true, chat: chat)
                            } label: {
                                Image(systemName: "video")
                            }.help("Видеозвонок").disabled(
                                model.isSynthetic || !model.status.linked || model.calls.call != nil)
                            Button {
                                callDevices = true
                            } label: {
                                Image(systemName: "headphones")
                            }.help("Устройства следующего звонка")
                            Button {
                                if showSearch || history.active {
                                    showSearch = false
                                    history.clear()
                                    historyFilter = .all
                                } else {
                                    showSearch = true
                                }
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .help("Поиск в переписке").accessibilityLabel("Поиск в переписке")
                            .accessibilityIdentifier("whatsapp.history.searchToggle")
                            Button {
                                showInfo.toggle()
                            } label: {
                                Image(systemName: "sidebar.right")
                            }
                            .help("Сведения о чате").accessibilityLabel("Сведения о чате")
                            .accessibilityIdentifier("whatsapp.chat.infoToggle")
                            MakoshMenu {
                                MakoshMenuItem("Настройки чата") { settings = true }
                                MakoshMenuItem("Обновить историю") { Task { await model.selectChat(chat.id) } }
                                MakoshMenuItem("Загрузить более ранние сообщения") { Task { await model.loadOlder() } }
                                    .disabled(!model.hasOlder || model.historyBusy)
                                Divider()
                                MakoshMenuItem("Постоянный архив и экспорт") {
                                    archivedMessage = nil
                                    archive = true
                                }
                                MakoshMenuItem(chat.archived ? "Вернуть из архива" : "Архивировать") {
                                    command(.init(.archive, on: !chat.archived))
                                }
                                MakoshMenuItem(chat.pinned ? "Открепить чат" : "Закрепить чат") {
                                    command(.init(.pinChat, on: !chat.pinned))
                                }
                                MakoshMenuItem("Прочитано") { command(.init(.read)) }
                                MakoshMenuItem("Отключить звук") { command(.init(.mute, duration: -1)) }
                                MakoshMenuItem("Включить звук") { command(.init(.mute, duration: 0)) }
                            } label: {
                                Image(systemName: "ellipsis")
                            }.makoshMenuStyle(.plain).accessibilityLabel("Действия чата").accessibilityIdentifier("whatsapp.chat.actions")
                        }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
                        Divider()
                        if showSearch || history.active { WhatsAppSearchBar(history: history, filter: $historyFilter) }
                        if displayed.isEmpty {
                            ContentUnavailableView(
                                history.active ? "Ничего не найдено" : "В этом чате пока нет сообщений", systemImage: "bubble.left",
                                description: Text(
                                    history.active
                                        ? "Измените запрос или фильтр поиска." : "Полученная история сохраняется и доступна офлайн.")
                            ).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                let chronological = Array(displayed.reversed())
                                LazyVStack(spacing: 8) {
                                    ForEach(Array(chronological.enumerated()), id: \.element.id) { index, message in
                                        if index == 0
                                            || !Calendar.current.isDate(
                                                Date(timeIntervalSince1970: TimeInterval(message.timestamp)),
                                                inSameDayAs: Date(timeIntervalSince1970: TimeInterval(chronological[index - 1].timestamp)))
                                        {
                                            Text(Date(timeIntervalSince1970: TimeInterval(message.timestamp)), style: .date)
                                                .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 12)
                                        }
                                        WhatsAppMessageRow(
                                            message: message,
                                            senderTitle: chat.group && !message.outgoing && !message.sender.isEmpty
                                                ? (model.chats.first { $0.id.utf8.elementsEqual(message.sender.utf8) }?.name
                                                    ?? message.sender) : nil,
                                            open: {
                                                Task {
                                                    if let sourceAccount,
                                                        let lease = await model.actions.download(
                                                            message, expectedAccount: sourceAccount)
                                                    {
                                                        preview?.remove()
                                                        preview = lease
                                                    }
                                                }
                                            },
                                            vote: { option in
                                                var a = WhatsAppAction(.vote, target: message.id)
                                                a.options = [option]
                                                command(a)
                                            }
                                        )
                                        .contextMenu {
                                            Button("Ответить") {
                                                if let sourceAccount {
                                                    model.composer.quote(message, expectedAccount: sourceAccount)
                                                }
                                            }
                                            Button("Версии сообщения") {
                                                archivedMessage = message.id
                                                archive = true
                                            }
                                            Button("Копировать") {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(message.text, forType: .string)
                                            }
                                            if let sourceAccount, message.details?.resourceID != nil, !message.deleted {
                                                FileActionsMenu(
                                                    handoff: { Self.fileHandoff(message, model: model, account: sourceAccount) },
                                                    protected: message.details?.protected == true)
                                            }
                                            MakoshMenu("Реакция") {
                                                ForEach(["👍", "❤️", "😂", "😮", "😢", "🙏", ""], id: \.self) { emoji in
                                                    MakoshMenuItem(emoji.isEmpty ? "Убрать реакцию" : emoji) {
                                                        command(.init(.react, text: emoji, target: message.id))
                                                    }
                                                }
                                            }
                                            Button(
                                                message.details?.starred == true ? "Убрать из избранного" : "В избранное"
                                            ) {
                                                command(
                                                    .init(.star, target: message.id, on: message.details?.starred != true))
                                            }
                                            Button(message.details?.pinned == true ? "Открепить" : "Закрепить") {
                                                command(.init(.pin, target: message.id, on: message.details?.pinned != true))
                                            }
                                            if !message.deleted {
                                                Button("Переслать…") {
                                                    actionMessage = message
                                                    actionKind = "forward"
                                                    actionText = ""
                                                }
                                            }
                                            if message.outgoing && !message.deleted {
                                                Button("Изменить…") {
                                                    actionMessage = message
                                                    actionKind = "edit"
                                                    actionText = message.text
                                                }
                                                Button("Удалить в WhatsApp…", role: .destructive) {
                                                    actionMessage = message
                                                    actionKind = "revoke"
                                                    actionText = ""
                                                }
                                            }
                                        }
                                    }
                                }.padding(20)
                            }.defaultScrollAnchor(.bottom).defaultScrollAnchor(.top, for: .alignment).accessibilityIdentifier(
                                "whatsapp.history")
                        }
                        if history.active, history.hasMore {
                            Button("Продолжить поиск") { Task { await history.loadMore() } }.disabled(history.busy)
                        }
                        WhatsAppComposeView(
                            model: model.composer, accountID: sourceAccount, chatID: sourceChat,
                            rich: { richCompose = true })
                    }.frame(minWidth: 380, maxWidth: .infinity).background { WorkspaceBackdrop(intensity: 0.3) }
                    if showInfo, let sourceAccount {
                        WhatsAppWorkspaceInfo(
                            model: model, accountID: sourceAccount, chat: chat,
                            info: $peerInfo, close: { showInfo = false }, settings: { settings = true }, dossier: dossier,
                            media: {
                                showSearch = true
                                historyFilter = .media
                            }
                        )
                        .frame(width: 264).background { WorkspaceBackdrop(intensity: 0.55) }
                    }
                }
                .modifier(WhatsAppReadMarker(model: model))
            } else {
                ContentUnavailableView(
                    "Выберите чат", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Переписка выбранного аккаунта откроется здесь."))
            }
        }.tint(WorkspaceStyle.accent)
            .sheet(isPresented: $richCompose) {
                if let sourceAccount, let sourceChat {
                    WhatsAppRichComposeView(model: model, accountID: sourceAccount, chatID: sourceChat)
                }
            }
            .sheet(isPresented: $archive) {
                if let sourceAccount, let sourceChat {
                    WhatsAppArchiveView(
                        worker: model.notificationWorker, accountID: sourceAccount, chat: sourceChat,
                        messageID: archivedMessage)
                }
            }
            .sheet(item: $groupRequest) { request in
                WhatsAppGroupCallPicker(
                    worker: model.notificationWorker, accountID: request.account, groupJID: request.chat, video: request.video
                ) { targets in
                    guard model.selectedAccountID == request.account, model.selectedChatID == request.chat,
                        model.actions.contextMatches(account: request.account, chat: request.chat)
                    else { return }
                    model.calls.startGroup(accountID: request.account, groupJID: request.chat, participants: targets, video: request.video)
                }
            }
            .onChange(of: model.selectedAccountID) { _, _ in groupRequest = nil }
            .onChange(of: model.selectedChatID) { _, _ in groupRequest = nil }
            .sheet(isPresented: $callDevices) { WhatsAppCallDevicesView(model: model.calls) }
            .sheet(isPresented: $settings) {
                if let chat = model.selectedChat, let sourceAccount {
                    WhatsAppChatSettingsView(
                        model: model.actions, chat: chat, accountID: sourceAccount,
                        synthetic: model.isSynthetic, worker: model.notificationWorker, avatarCache: model.avatarCache,
                        avatarRevision: model.status.avatarRevisions?[chat.id] ?? 0, avatarEpoch: model.status.avatarEpoch ?? 0,
                        dossier: dossier)
                }
            }
            .sheet(
                isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(
                        actionKind == "revoke"
                            ? "Удалить в WhatsApp?"
                            : actionKind == "edit" ? "Изменить сообщение" : "Переслать сообщение"
                    ).font(.title2.bold())
                    if actionKind == "revoke" {
                        Text("Архив Макоша сохранит сообщение и все его версии.")
                    } else {
                        TextField(actionKind == "forward" ? "JID получателя" : "Текст", text: $actionText)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Button("Отмена") { actionMessage = nil }
                        Spacer()
                        Button("Выполнить") {
                            if let m = actionMessage {
                                command(
                                    .init(
                                        actionKind == "edit" ? .edit : actionKind == "forward" ? .forward : .revoke,
                                        text: actionKind == "edit" ? actionText : "", target: m.id,
                                        to: actionKind == "forward" ? actionText : ""))
                                actionMessage = nil
                            }
                        }
                    }
                }.padding(24).frame(width: 460)
            }
            .sheet(
                isPresented: Binding(
                    get: { preview != nil },
                    set: {
                        if !$0 {
                            preview?.remove()
                            preview = nil
                        }
                    })
            ) { if let preview { WhatsAppFilePreview(lease: preview) } }
            .onDisappear {
                preview?.remove()
                preview = nil
            }
    }
    private func startCall(video: Bool, chat: WhatsAppChat) {
        guard let sourceAccount, sourceChat?.utf8.elementsEqual(chat.id.utf8) == true,
            model.actions.contextMatches(account: sourceAccount, chat: chat.id)
        else { return }
        if chat.group {
            groupRequest = .init(account: sourceAccount, chat: chat.id, video: video)
        } else {
            model.calls.start(accountID: sourceAccount, peer: chat.id, video: video)
        }
    }
    private var displayed: [WhatsAppMessage] { history.active ? history.messages : model.messages }
    private func command(_ action: WhatsAppAction) {
        guard let sourceAccount, let sourceChat else { return }
        Task {
            await model.actions.perform(action, expectedAccount: sourceAccount, expectedChat: sourceChat)
            await model.composer.refreshOutbox()
            await model.refresh()
        }
    }
}
