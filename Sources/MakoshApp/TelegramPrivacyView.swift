import SwiftUI
import MakoshTelegram

private extension TelegramPrivacyKind {
    var title: String {
        switch self {
        case .phoneNumber: "Номер телефона"; case .presence: "Последняя активность"; case .groupInvitations: "Группы и каналы"
        case .voiceCalls: "Звонки"; case .profilePhoto: "Фотографии профиля"; case .bio: "О себе"
        case .birthday: "Дата рождения"; case .forwards: "Пересылка сообщений"; case .phoneDiscovery: "Поиск по номеру"; case .callP2P: "Peer-to-Peer"
        }
    }
    var question: String {
        switch self {
        case .phoneNumber: "Кто видит мой номер телефона?"; case .presence: "Кто видит время моего последнего посещения?"
        case .groupInvitations: "Кто может приглашать меня в группы и каналы?"; case .voiceCalls: "Кто может мне звонить?"
        case .profilePhoto: "Кто видит мои фотографии профиля?"; case .bio: "Кто видит информацию обо мне?"
        case .birthday: "Кто видит мою дату рождения?"; case .forwards: "Кто видит ссылку на мой профиль в пересланных сообщениях?"
        case .phoneDiscovery: "Кто может найти меня по номеру телефона?"; case .callP2P: "Кому разрешено прямое соединение при звонках?"
        }
    }
}
private extension TelegramPrivacyAudience {
    var title: String { switch self { case .everybody: "Все"; case .contacts: "Мои контакты"; case .nobody: "Никто" } }
}
private struct PrivacyDraft: Identifiable {
    let id = UUID()
    let change: TelegramPrivacyChange
    let context: UUID
}

struct TelegramPrivacyView: View {
    @ObservedObject var controller: TelegramPrivacyController
    let synthetic: Bool
    @State private var selected: TelegramPrivacyKind?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(privacyStatus(controller)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if controller.status == .loading || controller.mutationStatus == .saving { ProgressView().controlSize(.small) }
                Button("Обновить") { controller.refresh() }.disabled(controller.mutationStatus == .saving).accessibilityIdentifier("telegram.privacy.refresh")
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if let snapshot = controller.snapshot {
                Form {
                    Section("Приватность") {
                        ForEach(TelegramPrivacyKind.allCases.filter { $0 != .phoneDiscovery && $0 != .callP2P }) { kind in
                            Button { selected = kind } label: {
                                HStack { Text(kind.title); Spacer(); Text(snapshot.settings[kind]?.audience?.title ?? "Особое правило").foregroundStyle(.secondary); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                                    .frame(minHeight: 36).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("telegram.privacy.open.\(kind.rawValue)")
                        }
                    }
                }.formStyle(.grouped)
            } else if controller.status == .loading { Spacer(); ProgressView("Загружаем настройки…"); Spacer() }
            else { ContentUnavailableView("Настройки приватности недоступны", systemImage: "hand.raised", description: Text("Подключите выбранный аккаунт Telegram или повторите загрузку.")) }
        }
        .onAppear { controller.open() }.onDisappear { controller.close() }
        .onChange(of: controller.snapshot?.accountID) { _, _ in selected = nil }
        .sheet(item: $selected) { kind in TelegramPrivacyDetailView(controller: controller, kind: kind, synthetic: synthetic) { selected = nil } }
    }
}

private struct TelegramPrivacyDetailView: View {
    @ObservedObject var controller: TelegramPrivacyController
    let kind: TelegramPrivacyKind
    let synthetic: Bool
    let close: () -> Void
    @State private var draft: PrivacyDraft?
    @State private var confirmation: PrivacyDraft?
    @State private var related: TelegramPrivacyKind?
    @State private var validationFailed = false
    private var enabled: Bool { controller.status == .ready && controller.mutationStatus != .saving && controller.mutationStatus != .uncertain }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(kind.title).font(.headline); Spacer(); Button("Готово", action: close).accessibilityIdentifier("telegram.privacy.detail.close") }.padding()
            Divider()
            Text(validationFailed ? "Настройки изменились. Обновите их и подтвердите заново." : draft != nil && enabled ? "Изменения ещё не сохранены" : privacyStatus(controller, kind: kind))
                .font(.caption).foregroundStyle(.secondary).padding(10).accessibilityIdentifier("telegram.privacy.status")
            if let current = controller.snapshot?.settings[kind] {
                Form {
                    Section(kind.question) {
                        if let audience = current.audience {
                            Picker(kind.question, selection: Binding(get: { draft?.change.audience ?? audience }, set: { value in
                                validationFailed = false
                                draft = current.replacingAudience(value) == nil ? nil : .init(change: .init(expected: current, audience: value), context: controller.contextID)
                            })) {
                                ForEach(TelegramPrivacyAudience.allCases.filter { kind != .phoneDiscovery || $0 != .nobody }) { value in Text(value.title).tag(value).accessibilityIdentifier("telegram.privacy.audience.\(value.rawValue)") }
                            }.labelsHidden().pickerStyle(.radioGroup).disabled(!enabled).accessibilityIdentifier("telegram.privacy.audience")
                        } else { Text("Особое правило"); Text("Это правило сохраняется без изменений.").font(.caption).foregroundStyle(.secondary) }
                        if kind == .presence { Text("Скрытие точного времени посещения также ограничивает просмотр времени посещения других пользователей в Telegram.").font(.caption).foregroundStyle(.secondary) }
                        if kind == .forwards { Text("Это правило управляет ссылкой на профиль при пересылке сообщения.").font(.caption).foregroundStyle(.secondary) }
                        if kind == .callP2P { Text("При прямом соединении собеседник может видеть ваш IP-адрес. Если оно запрещено, звонок проходит через серверы Telegram.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Section("Существующие исключения") {
                        let labels = exceptionLabels(current.rules)
                        if labels.isEmpty { Text("Нет исключений").foregroundStyle(.secondary) }
                        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in Text(label) }
                        Text("Исключения сохраняются при смене основного правила.").font(.caption).foregroundStyle(.secondary)
                    }
                    if kind == .phoneNumber { relatedRow(.phoneDiscovery) }
                    if kind == .voiceCalls { relatedRow(.callP2P) }
                    Section {
                        Button("Сохранить") { confirmation = draft }.disabled(!enabled || draft == nil).accessibilityIdentifier("telegram.privacy.save")
                        if draft != nil { Button("Отменить изменения") { draft = nil }.accessibilityIdentifier("telegram.privacy.discardDraft") }
                    }
                }.formStyle(.grouped)
            } else { ContentUnavailableView("Настройки недоступны", systemImage: "hand.raised") }
        }.frame(width: 520, height: 630)
        .onChange(of: controller.contextID) { _, _ in draft = nil; confirmation = nil }
        .sheet(item: $related) { kind in TelegramPrivacyDetailView(controller: controller, kind: kind, synthetic: synthetic) { related = nil } }
        .alert("Изменить приватность?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { request in
            Button("Отмена", role: .cancel) { confirmation = nil }
            Button("Подтвердить") {
                let accepted = controller.apply(request.change, contextID: request.context)
                validationFailed = !accepted; if accepted { draft = nil }; confirmation = nil
            }
        } message: { request in Text((synthetic ? "Симуляция. " : "") + "\(kind.title): \(request.change.audience.title). Существующие исключения сохранятся.") }
    }
    private func relatedRow(_ value: TelegramPrivacyKind) -> some View {
        Section {
            Button { related = value } label: { HStack { Text(value.title); Spacer(); Text(controller.snapshot?.settings[value]?.audience?.title ?? "Особое правило").foregroundStyle(.secondary); Image(systemName: "chevron.right") } }
                .buttonStyle(.plain).disabled(!enabled || draft != nil).accessibilityIdentifier("telegram.privacy.open.\(value.rawValue)")
            if draft != nil { Text("Сохраните или отмените изменения перед переходом.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private func exceptionLabels(_ rules: [TelegramPrivacyRule]) -> [String] {
    rules.compactMap { rule in
        switch rule {
        case let .allowUsers(ids): ids.isEmpty ? nil : "Всегда разрешено · пользователей: \(ids.count)"
        case let .denyUsers(ids): ids.isEmpty ? nil : "Никогда не разрешено · пользователей: \(ids.count)"
        case let .allowChats(ids): ids.isEmpty ? nil : "Всегда разрешено · групп: \(ids.count)"
        case let .denyChats(ids): ids.isEmpty ? nil : "Никогда не разрешено · групп: \(ids.count)"
        case .closeFriends: "Всегда разрешено · близкие друзья"; case .premium: "Всегда разрешено · Telegram Premium"
        case .bots: "Всегда разрешено · боты"; case .denyBots: "Никогда не разрешено · боты"; case .denyContacts: "Никогда не разрешено · контакты"
        default: nil
        }
    }
}
@MainActor private func privacyStatus(_ controller: TelegramPrivacyController, kind: TelegramPrivacyKind? = nil) -> String {
    let mutation = kind.map { controller.mutationStatus(for: $0) } ?? controller.mutationStatus
    if mutation == .uncertain { return "Результат неизвестен. Обновите настройки перед новым действием." }
    if controller.status == .failed || controller.status == .timedOut {
        return mutation == .saved ? "Изменение подтверждено; настройки не удалось обновить." : "Не удалось загрузить настройки. Повторите обновление."
    }
    switch mutation {
    case .idle: return "Настройки выбранного аккаунта Telegram"
    case .saving: return "Сохраняем…"; case .saved: return "Изменение подтверждено"
    case .changed: return "Настройки изменились. Проверьте их и подтвердите заново."
    case .failed: return "Telegram отклонил изменение."; case .uncertain: return "Обновите настройки."
    }
}
