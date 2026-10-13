import SwiftUI
import MakoshTelegram

struct TelegramSidebarView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var search: TelegramSearchModel
    @ObservedObject private var globalSearch: TelegramSearchModel
    @ObservedObject private var forumTopics: TelegramForumTopicsController
    @State private var connectionPresented = false
    @State private var settingsPresented = false
    @FocusState private var searchFocused: Bool
    init(model: TelegramModel) { self.model = model; self.search = model.search; self.globalSearch = model.globalSearch; self.forumTopics = model.forumTopics }
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
                    Button { model.isForumTopicsListPresented = false } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).help("Вернуться к диалогам")
                        .accessibilityLabel("Вернуться к диалогам").accessibilityIdentifier("telegram.forum.back")
                }
                if model.phase == .ready && model.chatFolder == .archive {
                    Button { search.chatQuery = ""; model.chatFolder = .inbox } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).help("Вернуться к диалогам")
                        .accessibilityLabel("Вернуться к диалогам").accessibilityIdentifier("telegram.folder.back")
                }
                Text(showsForum ? (model.selectedChat?.title ?? "Темы") : model.phase == .ready ? (model.chatFolder == .archive ? "Архив" : "Диалоги") : "Telegram")
                    .font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                TelegramArchiveButton(archive: model.archive)
                Button { settingsPresented = true } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Настройки Telegram").accessibilityLabel("Настройки Telegram")
                    .accessibilityIdentifier("telegram.settings.open")
                Button { connectionPresented = true } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.plain).help("О подключении")
                    .accessibilityLabel("О подключении Telegram").accessibilityIdentifier("telegram.connection.open")
                    .popover(isPresented: $connectionPresented) { connectionDetails }
            }.padding(.horizontal, 12).frame(height: 50)
            Divider()
            if model.phase == .ready && !showsForum {
                TextField("Поиск", text: $search.chatQuery).textFieldStyle(.roundedBorder).focused($searchFocused)
                    .padding(.horizontal, 10).frame(height: 40).accessibilityIdentifier("telegram.chatSearch")
                    .onChange(of: search.chatQuery) { _, query in globalSearch.messageQuery = query }
                if searchFocused || searching {
                    TelegramSearchMediaTabs(selection: $globalSearch.mediaFilter)
                    HStack {
                        Picker("Диалоги", selection: $globalSearch.scope) {
                            ForEach(TelegramSearchScope.allCases) { scope in Text(scope.title).tag(scope) }
                        }.labelsHidden().accessibilityIdentifier("telegram.globalSearch.scope")
                        Spacer(minLength: 4)
                        Button("Отмена") {
                            search.chatQuery = ""; globalSearch.clearMessageSearch(); searchFocused = false
                        }.buttonStyle(.plain).accessibilityIdentifier("telegram.globalSearch.close")
                    }.padding(.horizontal, 10).padding(.bottom, 8)
                    if let chat = globalSearch.scopedChat {
                        HStack {
                            Text("В: \(chat.title)").font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            Button { globalSearch.scopedChat = nil } label: { Image(systemName: "xmark.circle.fill") }
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
                    ContentUnavailableView(search.chatStatus == .ready ? "Диалоги не найдены" : "Поиск диалогов", systemImage: "magnifyingglass", description: Text(search.chatStatus == .ready ? "Попробуйте другое название. В кэше могут быть ещё не загружены все диалоги." : "Результаты появятся после завершения запроса.")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.chatPage.isLoading {
                    ProgressView("Загрузка диалогов…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(model.chatFolder == .archive ? "Нет загруженных архивных диалогов" : "Нет загруженных диалогов", systemImage: "bubble.left.and.bubble.right", description: Text(model.phase == .ready ? "В этом списке пока нет диалогов. Можно обновить загрузку." : "Диалоги появятся после подключения вашего отдельного сеанса.")).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List(selection: $model.selectedChatID) {
                    if showsArchiveEntry { archiveEntry.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)) }
                    ForEach(visibleChats) { chat in
                        HStack(spacing: 10) {
                            TelegramChatListAvatar(chat: chat, store: model.avatars, isSelected: model.selectedChatID == chat.id)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack { Text(chat.title).font(.headline).lineLimit(1); Spacer(minLength: 4) }
                                HStack(alignment: .top) {
                                    Text(chat.preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                    Spacer(minLength: 4)
                                    if chat.unreadCount > 0 {
                                        Text("\(chat.unreadCount)").font(.caption.monospacedDigit())
                                            .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(Color.accentColor, in: Capsule())
                                    }
                                }
                            }
                        }.frame(height: 70).listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                            .tag(chat.id).accessibilityIdentifier("telegram.chat.\(chat.id)")
                    }
                }.listStyle(.inset).accessibilityIdentifier("telegram.chats")
            }
            if model.phase == .ready && !searching && !showsForum {
                TelegramPaginationBar(page: model.chatPage, prefix: "telegram.chatPage",
                    previous: model.loadOlderChats, next: model.loadNewerChats,
                    latest: model.showLatestChats, retry: model.retryChatPage)
                    .padding(12)
            }
        }.frame(maxHeight: .infinity, alignment: .top)
            .sheet(isPresented: $settingsPresented) {
                TelegramSettingsView(sessions: model.accountSessions, privacy: model.accountPrivacy, blockedUsers: model.accountBlockedUsers, twoStep: model.accountTwoStep, notifications: model.notifications, chats: model.chats, synthetic: model.isSyntheticPreview) { settingsPresented = false }
            }
            .onAppear { forumTopics.setVisible(true) }
            .onDisappear { forumTopics.setVisible(false) }
            .onChange(of: model.selectedChatID) { _, _ in model.isForumTopicsListPresented = true }
            .onReceive(model.notifications.$activationRequest.dropFirst()) { _ in settingsPresented = false }
    }

    private var archiveEntry: some View {
        Button { model.chatFolder = .archive } label: {
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
            Button("Остановить подключение") { connectionPresented = false; model.disconnect() }
                .help("Останавливает локальное подключение и сохраняет кэш. Не завершает сеанс на серверах Telegram.")
                .disabled(model.isSyntheticPreview).accessibilityIdentifier("telegram.disconnect")
        }.padding(16).frame(width: 300, alignment: .leading)
    }
}
