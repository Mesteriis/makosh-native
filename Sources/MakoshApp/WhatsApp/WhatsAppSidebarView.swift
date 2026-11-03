import MakoshWhatsApp
// Layout adapted from WhatsApp Zen MainView.swift / Components.swift (MIT).
// See LICENSES/WhatsApp-Zen-MIT.txt and docs/reference-interface.md.
import SwiftUI

struct WhatsAppSidebarView: View {
    @ObservedObject var model: WhatsAppWorkspaceModel
    @ObservedObject var navigation: WhatsAppWorkspaceNavigationState
    private var chats: [WhatsAppChat] { model.chats.filter { navigation.matches($0) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(navigation.filter == .all ? "Чаты" : navigation.filter.rawValue).font(.title2.bold())
                Text("\(chats.count)").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }.padding(.horizontal, 20).frame(height: WorkspaceStyle.mailPaneHeaderHeight)
            Divider()
            if chats.isEmpty {
                ContentUnavailableView(
                    model.accounts.isEmpty ? "Подключите WhatsApp" : "Нет чатов",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(
                        model.accounts.isEmpty
                            ? "Добавьте аккаунт через меню в верхней панели." : "Проверьте выбранный аккаунт, раздел и поиск.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(chats) { chat in
                            Button {
                                Task { await model.selectChat(chat.id) }
                            } label: {
                                WhatsAppChatRow(chat: chat, model: model).padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .background(
                                        model.selectedChatID == chat.id ? WorkspaceStyle.accent.opacity(0.19) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityIdentifier("whatsapp.chat.\(chat.id)")
                                .accessibilityValue(model.selectedChatID == chat.id ? "Выбрано" : "")
                        }
                    }.padding(10)
                }
            }
            Button {
                navigation.filter = navigation.filter == .archived ? .all : .archived
            } label: {
                HStack {
                    Image(systemName: "archivebox")
                    Text(navigation.filter == .archived ? "Все чаты" : "Архив")
                    Spacer()
                    Text("\(model.chats.filter(\.archived).count)").foregroundStyle(.secondary)
                }.padding(16).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent).accessibilityIdentifier("whatsapp.workspace.archive")
        }
    }
}
private struct WhatsAppChatRow: View {
    let chat: WhatsAppChat
    @ObservedObject var model: WhatsAppWorkspaceModel
    var body: some View {
        HStack(spacing: 11) {
            WhatsAppAvatarView(
                name: chat.name, group: chat.group,
                scope: model.selectedAccountID.map { .init(accountID: $0, jid: chat.id) },
                revision: model.status.avatarRevisions?[chat.id] ?? 0, epoch: model.status.avatarEpoch ?? 0,
                worker: model.notificationWorker, cache: model.avatarCache)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.name).font(.body.weight(chat.unread > 0 ? .semibold : .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if chat.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(Date(timeIntervalSince1970: TimeInterval(chat.timestamp)), style: .time).font(
                        .caption
                    ).foregroundStyle(.secondary)
                }
                HStack {
                    Text(chat.preview ?? (chat.group ? "Групповой чат" : "Личная переписка")).font(.callout)
                        .foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 4)
                    if chat.unread > 0 {
                        Text("\(chat.unread)").font(.caption.bold()).foregroundStyle(.white).padding(
                            .horizontal, 6
                        ).padding(.vertical, 3).background(WorkspaceStyle.accent, in: Capsule())
                    }
                }
            }
        }.tint(WorkspaceStyle.accent)
    }
}
struct WhatsAppAvatar: View {
    let name: String, group: Bool
    var body: some View {
        ZStack {
            Circle().fill(WorkspaceStyle.accent.opacity(0.22))
            if group {
                Image(systemName: "person.2.fill").foregroundStyle(WorkspaceStyle.accent)
            } else {
                Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                    .font(.headline).foregroundStyle(WorkspaceStyle.accent)
            }
        }.frame(width: 44, height: 44).accessibilityHidden(true)
    }
}
