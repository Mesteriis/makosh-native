import SwiftUI
import MakoshTelegram

struct TelegramSidebarView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var search: TelegramSearchModel
    @ObservedObject private var globalSearch: TelegramSearchModel
    @ObservedObject private var forumTopics: TelegramForumTopicsController
    private let backupContext: TelegramArchiveBackupContext?
    @State private var connectionPresented = false
    @Environment(\.workspaceNavigation) private var workspaceNavigation
    @State private var settingsPresented = false
    @State private var downloadsPresented = false
    @FocusState private var searchFocused: Bool
    init(model: TelegramModel, backupContext: TelegramArchiveBackupContext? = nil) {
        self.model = model
        self.search = model.search
        self.globalSearch = model.globalSearch
        self.forumTopics = model.forumTopics
        self.backupContext = backupContext
    }
    private var searching: Bool { search.hasChatQuery || globalSearch.hasMessageQuery }
    private var showsForum: Bool {
        !searching && model.isForumTopicsListPresented && model.phase == .ready && forumTopics.snapshot?.chatID == model.selectedChatID
    }
    private var visibleChats: [TelegramChat] { search.hasChatQuery ? search.chats : model.chats }
    private var showsArchiveEntry: Bool { model.phase == .ready && model.chatFolder == .inbox && !search.hasChatQuery }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if showsForum {
                    Button {
                        model.isForumTopicsListPresented = false
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain).help("Вернуться к диалогам")
                    .accessibilityLabel("Вернуться к диалогам").accessibilityIdentifier("telegram.forum.back")
                }
                if model.phase == .ready && model.chatFolder == .archive {
                    Button {
                        search.chatQuery = ""
                        model.chatFolder = .inbox
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain).help("Вернуться к диалогам")
                    .accessibilityLabel("Вернуться к диалогам").accessibilityIdentifier("telegram.folder.back")
                }
                Text(showsForum ? (model.selectedChat?.title ?? "Темы") : model.phase == .ready ? (model.workspaceFolderTitle) : "Telegram")
                    .font(.system(size: 20, weight: .bold)).lineLimit(1)
                Spacer(minLength: 4)
                TelegramArchiveButton(archive: model.archive, backupContext: backupContext)
                MakoshMenu {
                    MakoshMenuItem("Загрузки") { downloadsPresented = true }
                    MakoshMenuItem("Настройки Telegram") {
                        if WorkspaceNavigation.route(.telegram, via: workspaceNavigation) == .sheet { settingsPresented = true }
                    }
                    MakoshMenuItem("О подключении") { connectionPresented = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("Действия Telegram")
                .popover(isPresented: $connectionPresented) { connectionDetails }
            }.padding(.horizontal, 16).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
            Divider()
            if model.phase == .ready && !showsForum {
                if searchFocused || searching {
                    TelegramSearchMediaTabs(selection: $globalSearch.mediaFilter)
                    HStack {
                        MakoshPicker("Диалоги", selection: $globalSearch.scope) {
                            ForEach(TelegramSearchScope.allCases) { scope in Text(scope.title).tag(scope) }
                        }.labelsHidden().accessibilityIdentifier("telegram.globalSearch.scope")
                        Spacer(minLength: 4)
                        Button("Отмена") {
                            search.chatQuery = ""
                            globalSearch.clearMessageSearch()
                            searchFocused = false
                        }.buttonStyle(.plain).accessibilityIdentifier("telegram.globalSearch.close")
                    }.padding(.horizontal, 10).padding(.bottom, 8)
                    if let chat = globalSearch.scopedChat {
                        HStack {
                            Text("В: \(chat.title)").font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            Button {
                                globalSearch.scopedChat = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).accessibilityLabel("Сбросить диалог поиска")
                            .accessibilityIdentifier("telegram.globalSearch.inChat.clear")
                        }.padding(.horizontal, 12).padding(.bottom, 8)
                    }
                }
            }
            if searching {
                TelegramGlobalSearchResultsView(model: model)
            } else if showsForum {
                TelegramForumTopicsListView(model: model, topics: forumTopics)
            } else if visibleChats.isEmpty {
                if showsArchiveEntry { archiveEntry }
                if search.hasChatQuery {
                    ContentUnavailableView(
                        search.chatStatus == .ready ? "Диалоги не найдены" : "Поиск диалогов", systemImage: "magnifyingglass",
                        description: Text(
                            search.chatStatus == .ready
                                ? "Попробуйте другое название. В кэше могут быть ещё не загружены все диалоги."
                                : "Результаты появятся после завершения запроса.")
                    ).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.chatPage.isLoading {
                    ProgressView("Загрузка диалогов…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        model.chatFolder == .archive ? "Нет загруженных архивных диалогов" : "Нет загруженных диалогов",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(
                            model.phase == .ready
                                ? "В этом списке пока нет диалогов. Можно обновить загрузку."
                                : "Диалоги появятся после подключения вашего отдельного сеанса.")
                    ).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(visibleChats) { chat in
                                Button {
                                    model.selectedChatID = chat.id
                                } label: {
                                    HStack(spacing: 12) {
                                        TelegramChatListAvatar(
                                            chat: chat, store: model.avatars, isSelected: model.selectedChatID == chat.id)
                                        VStack(alignment: .leading, spacing: 5) {
                                            HStack {
                                                Text(chat.title).font(.system(size: 14, weight: .semibold))
                                                Spacer(minLength: 3)
                                                if chat.unreadCount > 0 {
                                                    Text("\(chat.unreadCount)").font(.caption).foregroundStyle(WorkspaceStyle.accent)
                                                }
                                            }
                                            Text(chat.preview.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 13))
                                                .foregroundStyle(.secondary).lineLimit(2)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.padding(12).frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
                                        .background(
                                            model.selectedChatID == chat.id ? WorkspaceStyle.accent.opacity(0.22) : .clear,
                                            in: RoundedRectangle(cornerRadius: 10)
                                        )
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(chat.id)
                                    .accessibilityValue(model.selectedChatID == chat.id ? "Выбрано" : "")
                                    .accessibilityIdentifier("telegram.chat.\(chat.id)")
                            }
                        }.padding(8)
                    }.focusable().focusEffectDisabled()
                        .onKeyPress(.downArrow) {
                            moveSelection(1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            moveSelection(-1)
                            return .handled
                        }
                        .onChange(of: model.selectedChatID) { _, id in if let id { proxy.scrollTo(id) } }
                }.accessibilityIdentifier("telegram.chats")
            }
            if model.phase == .ready && !searching && !showsForum {
                TelegramPaginationBar(
                    page: model.chatPage, prefix: "telegram.chatPage",
                    previous: model.loadOlderChats, next: model.loadNewerChats,
                    latest: model.showLatestChats, retry: model.retryChatPage
                )
                .padding(12)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
            .sheet(isPresented: $downloadsPresented) { TelegramDownloadsView(model: model) }
            // Only a sidebar hosted without the workspace falls back to the former sheet.
            .sheet(isPresented: $settingsPresented) { TelegramWorkspaceSettings(model: model) { settingsPresented = false } }
            .onReceive(model.notifications.$activationRequest.dropFirst()) { _ in settingsPresented = false }
            .onAppear { forumTopics.setVisible(true) }
            .onDisappear { forumTopics.setVisible(false) }
            .onChange(of: model.selectedChatID) { _, _ in model.isForumTopicsListPresented = true }
    }

    private func moveSelection(_ offset: Int) {
        guard !visibleChats.isEmpty else { return }
        let current = visibleChats.firstIndex { $0.id == model.selectedChatID } ?? (offset > 0 ? -1 : visibleChats.count)
        model.selectedChatID = visibleChats[min(max(current + offset, 0), visibleChats.count - 1)].id
    }
    private var archiveEntry: some View {
        Button {
            model.chatFolder = .archive
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "archivebox").frame(width: 50, height: 50)
                    .foregroundStyle(.secondary)
                Text("Архив").font(.headline)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).frame(height: 70).contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 10).accessibilityIdentifier("telegram.folder.archive")
    }

    private var connectionDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Подключение Telegram").font(.headline)
            Text(model.connectionDescription).font(.callout)
            Text("Неофициальный канал Макош").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Остановить подключение") {
                connectionPresented = false
                model.stopConnection()
            }
            .help("Останавливает локальное подключение и сохраняет кэш. Не завершает сеанс на серверах Telegram.")
            .disabled(model.isSyntheticPreview).accessibilityIdentifier("telegram.disconnect")
        }.padding(16).frame(width: 300, alignment: .leading)
    }
}
