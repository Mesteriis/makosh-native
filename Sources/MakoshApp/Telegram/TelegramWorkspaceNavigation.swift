import SwiftUI
import MakoshTelegram

struct TelegramWorkspaceNavigation: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var search: TelegramSearchModel
    @State private var downloads = false
    @State private var startChat = false
    init(model: TelegramModel) {
        self.model = model
        search = model.search
    }
    var body: some View {
        HStack(spacing: 10) {
            MakoshMenu {
                Text(model.connectionDescription).font(.caption).foregroundStyle(.secondary)
            } label: {
                Label("Аккаунт Telegram", systemImage: "person.crop.circle")
            }
            .makoshMenuStyle(.bordered).makoshMenuIndicator(.visible)
            .accessibilityIdentifier("telegram.workspace.account")
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск в Telegram", text: $search.chatQuery).textFieldStyle(.plain)
                    .accessibilityIdentifier("telegram.chatSearch")
                    .onChange(of: search.chatQuery) { _, query in model.globalSearch.messageQuery = query }
                if !search.chatQuery.isEmpty {
                    Button {
                        search.chatQuery = ""
                        model.globalSearch.clearMessageSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).accessibilityLabel("Очистить поиск")
                }
            }.padding(11).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)) }
            Button {
                downloads = true
            } label: {
                Image(systemName: "arrow.down.circle")
            }
            .buttonStyle(.plain).accessibilityLabel("Загрузки Telegram")
            Button {
                search.chatQuery = ""
                model.globalSearch.clearMessageSearch()
                startChat = true
            } label: {
                Label("Новый чат", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderedProminent).controlSize(.regular).accessibilityIdentifier("telegram.workspace.newChat")
        }.padding(.horizontal, 8).frame(height: 44).background { WorkspaceBackdrop(intensity: 0.5) }
            .sheet(isPresented: $downloads) { TelegramDownloadsView(model: model) }
            .sheet(isPresented: $startChat) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Найти собеседника").font(.title2.bold())
                        Spacer()
                        Button("Закрыть") { startChat = false }
                    }
                    TextField("Имя или @username", text: $search.chatQuery).textFieldStyle(.roundedBorder)
                        .onChange(of: search.chatQuery) { _, query in model.globalSearch.messageQuery = query }
                    TelegramGlobalSearchResultsView(model: model) { startChat = false }
                }.padding(20).frame(width: 540, height: 620).makoshAppearance()
                    .onChange(of: model.selectedChatID) { _, _ in startChat = false }
                    .onDisappear {
                        search.chatQuery = ""
                        model.globalSearch.clearMessageSearch()
                    }
            }
    }
}

struct TelegramFolderRail: View {
    @ObservedObject var model: TelegramModel
    @Environment(\.workspaceNavigation) private var workspaceNavigation
    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(spacing: 8) {
                    entry(
                        "Все", symbol: "bubble.left.and.bubble.right",
                        selected: model.chatFolder == .inbox && model.workspaceFolderID == nil
                    ) { model.selectWorkspaceFolder(nil) }
                    ForEach(model.workspaceFolders) { folder in
                        entry(folder.title, symbol: "folder", selected: model.chatFolder == .inbox && model.workspaceFolderID == folder.id)
                        { model.selectWorkspaceFolder(folder.id) }
                        .accessibilityIdentifier("telegram.folder.custom.\(folder.id)")
                    }
                    entry("Архив", symbol: "archivebox", selected: model.chatFolder == .archive) { model.showWorkspaceArchive() }
                }.padding(.top, 10)
            }
        }.padding(.horizontal, 5).padding(.bottom, 12).frame(width: 64)
            .background(WorkspaceStyle.base)
    }

    private func entry(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 22, weight: .regular))
                Text(title).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
            }.frame(width: 54, height: 60)
                .foregroundStyle(selected ? WorkspaceStyle.accent : .secondary)
                .background(selected ? WorkspaceStyle.accent.opacity(0.19) : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(selected ? "Выбрано" : "")
    }
}

struct TelegramWorkspaceSettings: View {
    @ObservedObject var model: TelegramModel
    var embedded = false
    let close: () -> Void
    var body: some View {
        TelegramSettingsView(
            sessions: model.accountSessions, webSessions: model.webSessions, privacy: model.accountPrivacy,
            blockedUsers: model.accountBlockedUsers, twoStep: model.accountTwoStep, notifications: model.notifications,
            autoDownload: model.autoDownloadSettings, cache: model.cache, cacheMaintenance: model.cacheMaintenance, proxy: model.proxy,
            avatarEditing: model.avatarEditing, appearanceCatalog: model.appearanceCatalog,
            avatars: model.avatars, chats: model.chats, synthetic: model.isSyntheticPreview, embedded: embedded,
            close: embedded ? nil : close)
    }
}
