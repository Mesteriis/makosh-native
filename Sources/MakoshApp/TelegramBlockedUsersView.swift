import SwiftUI
import MakoshTelegram

struct TelegramBlockedUsersView: View {
    @ObservedObject var controller: TelegramBlockedUsersController
    let synthetic: Bool
    let close: () -> Void
    @State private var confirmation: TelegramBlockedUserChange?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Заблокированные пользователи").font(.headline)
                Spacer()
                Button("Готово", action: close).accessibilityIdentifier("telegram.blocked.close")
            }.padding(16)
            Divider()
            HStack {
                Text(blockedUsersStatus(controller)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Обновить", action: controller.refresh).disabled(controller.mutationStatus == .saving)
                    .accessibilityIdentifier("telegram.blocked.refresh")
            }.padding(16)
            if let snapshot = controller.snapshot {
                if snapshot.users.isEmpty { ContentUnavailableView("Нет заблокированных пользователей", systemImage: "hand.raised.slash") }
                else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(snapshot.users) { user in
                                HStack {
                                    Text(user.title)
                                    Spacer()
                                    Button("Разблокировать") { confirmation = controller.change(userID: user.id, title: user.title) }
                                        .disabled(controller.change(userID: user.id, title: user.title) == nil)
                                        .accessibilityIdentifier("telegram.blocked.unblock.\(user.id)")
                                }.frame(minHeight: 46).padding(.horizontal, 16)
                                    .accessibilityElement(children: .contain)
                                Divider()
                            }
                        }
                    }.accessibilityIdentifier("telegram.blocked.list")
                }
                Text("Заблокировать пользователя можно в его карточке. Сообщения и сохранённые файлы остаются в Макоше.")
                    .font(.caption).foregroundStyle(.secondary).padding(16)
            } else if controller.status == .loading {
                Spacer(); ProgressView("Загружаем список…"); Spacer()
            } else {
                ContentUnavailableView("Список недоступен", systemImage: "hand.raised.slash", description: Text("Повторите загрузку для выбранного аккаунта Telegram."))
            }
        }.frame(width: 520, height: 580)
        .onAppear { controller.open() }.onDisappear { controller.close() }
        .onChange(of: controller.contextID) { _, _ in confirmation = nil }
        .alert("Разблокировать пользователя?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { change in
            Button("Отмена", role: .cancel) { confirmation = nil }
            Button("Разблокировать") { _ = controller.apply(change); confirmation = nil }
        } message: { change in Text((synthetic ? "Симуляция. " : "") + change.title + ". История переписки сохраняется.") }
    }
}

struct TelegramProfileBlockAction: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject var controller: TelegramBlockedUsersController
    let profile: TelegramContactProfile
    let profileContextID: UUID
    @State private var confirmation: TelegramBlockedUserChange?
    var body: some View {
        let change = model.blockedUserChange(profile, contextID: profileContextID)
        VStack(alignment: .leading, spacing: 8) {
            Button(change?.wasBlocked == true ? "Разблокировать" : "Заблокировать") { confirmation = change }
                .disabled(change == nil).accessibilityIdentifier("telegram.profile.blockUser")
            Text(blockedUsersStatus(controller)).font(.caption).foregroundStyle(.secondary)
            if controller.status == .failed || controller.status == .timedOut || controller.mutationStatus == .uncertain {
                Button("Обновить блокировки", action: controller.refresh).accessibilityIdentifier("telegram.profile.blockRefresh")
            }
        }
        .onAppear { controller.open() }.onDisappear { controller.close() }
        .onChange(of: controller.contextID) { _, _ in confirmation = nil }
        .alert(confirmation?.wasBlocked == true ? "Разблокировать пользователя?" : "Заблокировать пользователя?",
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { change in
            Button("Отмена", role: .cancel) { confirmation = nil }
            Button(change.wasBlocked ? "Разблокировать" : "Заблокировать", role: change.wasBlocked ? nil : .destructive) {
                if model.blockedUserChange(profile, contextID: profileContextID) == change { _ = controller.apply(change) }
                confirmation = nil
            }
        } message: { change in
            Text((model.isSyntheticPreview ? "Симуляция. " : "") + change.title + (change.wasBlocked ? ". Пользователь сможет снова связываться с вами в Telegram." : ". Telegram ограничит сообщения и звонки от этого пользователя.") + " История переписки сохраняется.")
        }
    }
}

@MainActor private func blockedUsersStatus(_ controller: TelegramBlockedUsersController) -> String {
    switch controller.mutationStatus {
    case .saving: return "Ждём подтверждение Telegram…"
    case .saved: return "Telegram подтвердил изменение"
    case .changed: return "Состояние изменилось. Проверьте обновлённый список."
    case .failed: return "Изменение не выполнено. Обновите список и повторите."
    case .uncertain: return "Результат неизвестен. Обновите список перед новым действием."
    case .idle: break
    }
    switch controller.status {
    case .loading: return "Загружаем список…"
    case .ready: return "Пользователей: \(controller.snapshot?.users.count ?? 0)"
    case .timedOut: return "Время ожидания истекло. Обновите список."
    case .failed: return "Не удалось загрузить полный список."
    default: return ""
    }
}
