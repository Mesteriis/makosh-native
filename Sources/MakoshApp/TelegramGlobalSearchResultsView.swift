import SwiftUI
import MakoshTelegram

struct TelegramGlobalSearchResultsView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var messages: TelegramSearchModel
    @ObservedObject private var chats: TelegramSearchModel
    @ObservedObject private var discovery: TelegramRemotePeerSearch
    @State private var allChats = false
    init(model: TelegramModel) {
        self.model = model; messages = model.globalSearch; chats = model.search; discovery = model.search.discovery
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if chats.hasChatQuery && messages.scopedChat == nil {
                    Text("Диалоги").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(12)
                    TelegramSearchStatusView(status: chats.chatStatus, retry: chats.retryChats).padding(.horizontal, 12)
                    ForEach(Array(chats.chats.prefix(allChats ? chats.chats.count : 5))) { chat in
                        HStack(spacing: 8) {
                            Button { model.selectedChatID = chat.id } label: {
                                HStack(spacing: 10) {
                                    TelegramChatListAvatar(chat: chat, store: model.avatars, isSelected: model.selectedChatID == chat.id)
                                    Text(chat.title).font(.callout.weight(.semibold)).lineLimit(2)
                                    Spacer(minLength: 0)
                                }.frame(minHeight: 60).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("telegram.globalSearch.chat.\(chat.id)")
                            Button { messages.scopedChat = chat } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.plain).help("Искать сообщения в этом диалоге")
                                .accessibilityLabel("Искать в \(chat.title)")
                                .accessibilityIdentifier("telegram.globalSearch.inChat.\(chat.id)")
                        }.padding(.horizontal, 10)
                    }
                    if !allChats && chats.chats.count > 5 {
                        Button("Ещё диалоги") { allChats = true }.padding(12)
                    }
                    Divider()
                }
                if chats.hasChatQuery && messages.scopedChat == nil && discovery.status != .idle {
                    Text("Глобальный поиск").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(12)
                    if discovery.status == .failed || discovery.status == .timedOut {
                        HStack {
                            Text(discovery.status == .timedOut ? "Поиск не завершился вовремя." : "Не удалось выполнить глобальный поиск.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Повторить", action: discovery.retry).accessibilityIdentifier("telegram.remoteSearch.retry")
                        }.padding(.horizontal, 12)
                    } else { TelegramSearchStatusView(status: discovery.status, retry: discovery.retry).padding(.horizontal, 12) }
                    let localIDs = Set(chats.chats.map(\.id))
                    ForEach(discovery.results.filter { !localIDs.contains($0.id) }) { peer in
                        let context = discovery.contextID
                        Button { model.openDiscoveredPeer(id: peer.id, contextID: context) } label: {
                            HStack(spacing: 10) {
                                TelegramChatListAvatar(chat: peer.chat, store: model.avatars, isSelected: model.selectedChatID == peer.id)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(peer.chat.title).font(.callout.weight(.semibold)).lineLimit(2)
                                    if let username = peer.username { Text("@" + username).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                            }.frame(minHeight: 60).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(discovery.isResolving)
                            .accessibilityIdentifier("telegram.globalSearch.remote.\(peer.id)").padding(.horizontal, 10)
                    }
                    if discovery.status == .ready && discovery.results.isEmpty {
                        Text("Пользователи и чаты не найдены").font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                    Divider()
                }
                if messages.hasMessageQuery {
                    HStack {
                        Text("Сообщения").font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(messages.totalMessages)").font(.caption.monospacedDigit())
                    }.foregroundStyle(.secondary).padding(12)
                    if let reason = messages.unavailableReason {
                        Text(reason).font(.caption).foregroundStyle(.secondary).padding(12)
                    } else {
                        TelegramSearchStatusView(status: messages.messageStatus, retry: messages.retryMessages).padding(.horizontal, 12)
                    }
                    if messages.scopedChat == nil && (messages.scope == .all || messages.scope == .privateChats)
                        && messages.messageQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && messages.mediaFilter != .all {
                        Text("Вложения секретных чатов доступны при поиске по тексту.")
                            .font(.caption).foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(messages.messages) { message in
                        let context = messages.resultContextID
                        Button { model.openGlobalSearchMessage(id: message.id, contextID: context) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(messages.resultChatTitle(id: message.id) ?? message.author).font(.callout.weight(.semibold)).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(message.date, format: .dateTime.day().month()).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(TelegramMessagePresentation.selectionLabel(for: message))
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            }.frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("telegram.globalSearch.result.\(message.id)")
                        Divider().padding(.leading, 12)
                    }
                    if messages.messageStatus == .ready && messages.messages.isEmpty {
                        Text("Сообщения не найдены").font(.callout).foregroundStyle(.secondary).padding(12)
                    }
                    if messages.canLoadMoreMessages {
                        Button("Ещё результаты", action: messages.loadMoreMessages).padding(12)
                            .accessibilityIdentifier("telegram.globalSearch.more")
                    }
                }
            }
        }.accessibilityIdentifier("telegram.globalSearch.results")
            .onChange(of: chats.chatQuery) { _, _ in allChats = false }
            .onAppear { updateDiscovery() }
            .onDisappear { chats.setRemoteDiscoveryEnabled(false) }
            .onChange(of: messages.mediaFilter) { _, _ in updateDiscovery() }
            .onChange(of: messages.scope) { _, _ in updateDiscovery() }
            .onChange(of: messages.scopedChat) { _, _ in updateDiscovery() }
    }
    private func updateDiscovery() {
        chats.setRemoteDiscoveryEnabled(messages.mediaFilter == .all && messages.scope == .all && messages.scopedChat == nil)
    }
}
