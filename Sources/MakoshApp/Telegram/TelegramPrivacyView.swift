import SwiftUI
import MakoshTelegram

private extension TelegramPrivacyKind {
    var title: String {
        switch self {
        case .phoneNumber: "Номер телефона"; case .presence: "Последняя активность"; case .groupInvitations: "Группы и каналы"
        case .voiceCalls: "Звонки"; case .profilePhoto: "Фотографии профиля"; case .bio: "О себе"
        case .birthday: "Дата рождения"; case .forwards: "Пересылка сообщений"; case .phoneDiscovery: "Поиск по номеру"; case .callP2P: "Peer-to-Peer"
        case .voiceMessages: "Голосовые и видеосообщения"; case .giftsAutoSave: "Подарки"; case .noPaidMessages: "Без платы за сообщения"
        }
    }
    var question: String {
        switch self {
        case .phoneNumber: "Кто видит мой номер телефона?"; case .presence: "Кто видит время моего последнего посещения?"
        case .groupInvitations: "Кто может приглашать меня в группы и каналы?"; case .voiceCalls: "Кто может мне звонить?"
        case .profilePhoto: "Кто видит мои фотографии профиля?"; case .bio: "Кто видит информацию обо мне?"
        case .birthday: "Кто видит мою дату рождения?"; case .forwards: "Кто видит ссылку на мой профиль в пересланных сообщениях?"
        case .phoneDiscovery: "Кто может найти меня по номеру телефона?"; case .callP2P: "Кому разрешено прямое соединение при звонках?"
        case .voiceMessages: "Кто может отправлять мне голосовые и видеосообщения?"
        case .giftsAutoSave: "Чьи подарки автоматически добавляются в мой профиль?"; case .noPaidMessages: "Кто может писать без платы?"
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

private struct PrivacyExceptionDraft: Identifiable {
    let id = UUID()
    let side: TelegramPrivacyExceptionSide
    let basis: TelegramPrivacyEditorBasis
    let staged: TelegramPrivacySetting
}

struct TelegramPrivacyView: View {
    @ObservedObject var controller: TelegramPrivacyController
    var blockedUsers: TelegramBlockedUsersController? = nil
    var twoStep: TelegramTwoStepController? = nil
    var avatarEditing: TelegramAvatarEditingController? = nil
    let synthetic: Bool
    @State private var blockedPresented = false
    @State private var twoStepPresented = false
    @State private var selected: TelegramPrivacyKind?
    @State private var globalPage: TelegramGlobalPrivacyPage?
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
                    if blockedUsers != nil || twoStep != nil {
                        Section {
                            if twoStep != nil {
                                Button { twoStepPresented = true } label: {
                                    HStack { Label("Двухэтапная аутентификация", systemImage: "lock"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                                        .frame(minHeight: 36).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("telegram.privacy.twoStep")
                            }
                            if blockedUsers != nil {
                            Button { blockedPresented = true } label: {
                                HStack { Label("Заблокированные пользователи", systemImage: "hand.raised.slash"); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                                    .frame(minHeight: 36).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("telegram.privacy.blockedUsers")
                            }
                        }
                    }
                    Section("Приватность") {
                        ForEach(TelegramPrivacyKind.allCases.filter { $0 != .phoneDiscovery && $0 != .callP2P && $0 != .noPaidMessages }) { kind in
                            Button { selected = kind } label: {
                                HStack { Text(kind.title); Spacer(); if kind == .voiceMessages && snapshot.capabilities?.isPremium != true { Image(systemName: "lock").foregroundStyle(.secondary) }; Text(snapshot.settings[kind]?.audience?.title ?? "Особое правило").foregroundStyle(.secondary); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                                    .frame(minHeight: 36).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("telegram.privacy.open.\(kind.rawValue)")
                        }
                        Button { globalPage = .messages } label: {
                            HStack { Text("Сообщения"); Spacer(); Text(snapshot.global?.messagePolicy.title ?? "Недоступно").foregroundStyle(.secondary); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                                .frame(minHeight: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(snapshot.global == nil || snapshot.capabilities == nil).accessibilityIdentifier("telegram.privacy.open.messages")
                    }
                }.formStyle(.grouped)
            } else if controller.status == .loading { Spacer(); ProgressView("Загружаем настройки…"); Spacer() }
            else { ContentUnavailableView("Настройки приватности недоступны", systemImage: "hand.raised", description: Text("Подключите выбранный аккаунт Telegram или повторите загрузку.")) }
        }
        .onAppear { controller.open() }.onDisappear { controller.close() }
        .onChange(of: controller.snapshot?.accountID) { _, _ in selected = nil; globalPage = nil }
        .sheet(isPresented: $blockedPresented) {
            if let blockedUsers { TelegramBlockedUsersView(controller: blockedUsers, synthetic: synthetic) { blockedPresented = false } }
        }
        .sheet(isPresented: $twoStepPresented) {
            if let twoStep { TelegramTwoStepView(controller: twoStep, synthetic: synthetic) { twoStepPresented = false } }
        }
        .sheet(item: $selected) { kind in TelegramPrivacyDetailView(controller: controller, kind: kind, synthetic: synthetic, avatarEditing: avatarEditing) { selected = nil } }
        .sheet(item: $globalPage) { page in TelegramGlobalPrivacyView(controller: controller, page: page, synthetic: synthetic) { globalPage = nil }.id(page.id) }
    }
}

struct TelegramPrivacyDetailView: View {
    @ObservedObject var controller: TelegramPrivacyController
    let kind: TelegramPrivacyKind
    let synthetic: Bool
    var avatarEditing: TelegramAvatarEditingController? = nil
    let close: () -> Void
    @State private var draft: PrivacyDraft?
    @State private var confirmation: PrivacyDraft?
    @State private var related: TelegramPrivacyKind?
    @State private var globalPage: TelegramGlobalPrivacyPage?
    @State private var validationFailed = false
    @State private var exceptionDraft: PrivacyExceptionDraft?
    private var activeDraft: PrivacyDraft? { draft?.context == controller.contextID ? draft : nil }
    private var enabled: Bool { controller.canEdit(kind) }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(kind.title).font(.headline); Spacer(); Button("Готово", action: close).accessibilityIdentifier("telegram.privacy.detail.close") }.padding()
            Divider()
            Text(validationFailed ? "Настройки изменились. Обновите их и подтвердите заново." : activeDraft != nil && enabled ? "Изменения ещё не сохранены" : privacyStatus(controller, kind: kind))
                .font(.caption).foregroundStyle(.secondary).padding(10).accessibilityIdentifier("telegram.privacy.status")
            if let current = controller.snapshot?.settings[kind] {
                let basis = TelegramPrivacyEditorBasis(controller: controller, kind: kind)
                Form {
                    Section(kind.question) {
                        if let audience = current.audience, kind != .noPaidMessages {
                            Picker(kind.question, selection: Binding(get: { activeDraft?.change.audience ?? audience }, set: { value in
                                validationFailed = false
                                let staged = activeDraft?.change.replacement ?? current
                                let next = staged.audience == value ? staged : staged.replacingAudience(value) ?? staged
                                guard let basis, basis.isCurrent(in: controller) else { validationFailed = true; return }
                                if next == current { draft = nil }
                                else if let change = basis.change(to: next, controller: controller) { draft = .init(change: change, context: basis.contextID) }
                                else { validationFailed = true }
                            })) {
                                ForEach(TelegramPrivacyAudience.allCases.filter { kind != .phoneDiscovery || $0 != .nobody }) { value in Text(value.title).tag(value).accessibilityIdentifier("telegram.privacy.audience.\(value.rawValue)") }
                            }.labelsHidden().pickerStyle(.radioGroup).disabled(!enabled).accessibilityIdentifier("telegram.privacy.audience")
                        } else { Text(kind == .noPaidMessages && current.audience == .contacts ? "Мои контакты" : "Особое правило"); Text("Это правило сохраняется без изменений.").font(.caption).foregroundStyle(.secondary) }
                        if kind == .voiceMessages && controller.snapshot?.capabilities?.isPremium != true { Text("Для изменения этих правил нужен Telegram Premium.").font(.caption).foregroundStyle(.secondary) }
                        if kind == .presence { Text("Скрытие точного времени посещения также ограничивает просмотр времени посещения других пользователей в Telegram.").font(.caption).foregroundStyle(.secondary) }
                        if kind == .forwards { Text("Это правило управляет ссылкой на профиль при пересылке сообщения.").font(.caption).foregroundStyle(.secondary) }
                        if kind == .callP2P { Text("При прямом соединении собеседник может видеть ваш IP-адрес. Если оно запрещено, звонок проходит через серверы Telegram.").font(.caption).foregroundStyle(.secondary) }
                    }
                    Section("Исключения") {
                        let staged = activeDraft?.change.replacement ?? current
                        if staged.audience != nil && kind != .phoneDiscovery {
                            if staged.audience != .nobody && kind != .noPaidMessages { exceptionRow(.deny, setting: staged, basis: basis) }
                            if staged.audience != .everybody { exceptionRow(.allow, setting: staged, basis: basis) }
                        }
                        let labels = exceptionLabels(staged.audience == nil || kind == .phoneDiscovery ? staged.rules : staged.rules.filter { $0 == .closeFriends || $0 == .premium || $0 == .bots || $0 == .denyBots || $0 == .denyContacts })
                        ForEach(Array(labels.enumerated()), id: \.offset) { _, label in Text(label) }
                        Text("Остальные правила сохраняются. Выбор человека или группы переносит их из противоположного списка.").font(.caption).foregroundStyle(.secondary)
                    }
                    if kind == .phoneNumber { relatedRow(.phoneDiscovery) }
                    if kind == .voiceCalls { relatedRow(.callP2P) }
                    if kind == .presence { relatedGlobalRow(.readTime) }
                    if kind == .giftsAutoSave { relatedGlobalRow(.giftTypes) }
                    if kind == .profilePhoto, let avatarEditing, let accountID = avatarEditing.accountID, controller.snapshot?.accountID == accountID {
                        Section("Публичная фотография") {
                            TelegramAvatarEditingButton(controller: avatarEditing, target: .init(accountID: accountID, peerID: accountID, kind: .fallback), title: "Изменить публичную фотографию")
                        }
                    }
                    Section {
                        Button("Сохранить") { confirmation = activeDraft }.disabled(!enabled || activeDraft == nil).accessibilityIdentifier("telegram.privacy.save")
                        if activeDraft != nil { Button("Отменить изменения") { draft = nil }.accessibilityIdentifier("telegram.privacy.discardDraft") }
                    }
                }.formStyle(.grouped)
            } else { ContentUnavailableView("Настройки недоступны", systemImage: "hand.raised") }
        }.frame(width: 520, height: 630)
        .onChange(of: controller.contextID) { _, _ in draft = nil; confirmation = nil; exceptionDraft = nil }
        .sheet(item: $exceptionDraft) { request in
            TelegramPrivacyExceptionEditor(directory: controller.peerDirectory, side: request.side, setting: request.staged, apply: { next in
                guard request.basis.isCurrent(in: controller) else { return false }
                guard next != request.staged else { return true }
                if next == request.basis.setting { draft = nil }
                else {
                    guard let change = request.basis.change(to: next, controller: controller) else { return false }
                    draft = .init(change: change, context: request.basis.contextID)
                }
                return true
            }, close: { exceptionDraft = nil })
        }
        .sheet(item: $related) { kind in TelegramPrivacyDetailView(controller: controller, kind: kind, synthetic: synthetic) { related = nil } }
        .sheet(item: $globalPage) { page in TelegramGlobalPrivacyView(controller: controller, page: page, synthetic: synthetic) { globalPage = nil }.id(page.id) }
        .alert("Изменить приватность?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { request in
            Button("Отмена", role: .cancel) { confirmation = nil }
            Button("Подтвердить") {
                let accepted = controller.apply(request.change, contextID: request.context)
                validationFailed = !accepted; if accepted { draft = nil }; confirmation = nil
            }
        } message: { request in Text((synthetic ? "Симуляция. " : "") + "\(kind.title): \(request.change.audience.title). Всегда разрешено: \(request.change.replacement?.exceptionPeers(.allow).count ?? 0); никогда: \(request.change.replacement?.exceptionPeers(.deny).count ?? 0). Исключение Premium: \(request.change.replacement?.rules.contains(.premium) == true ? "да" : "нет"); боты: \(request.change.replacement?.rules.contains(.bots) == true ? "да" : "нет").") }
    }
    private func relatedGlobalRow(_ page: TelegramGlobalPrivacyPage) -> some View {
        Section {
            Button { globalPage = page } label: { HStack { Text(page.title); Spacer(); Image(systemName: "chevron.right") } }
                .buttonStyle(.plain).disabled(!enabled || activeDraft != nil || controller.snapshot?.global == nil).accessibilityIdentifier("telegram.privacy.open.\(page.rawValue)")
            if activeDraft != nil { Text("Сначала сохраните или отмените изменения аудитории.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func exceptionRow(_ side: TelegramPrivacyExceptionSide, setting: TelegramPrivacySetting, basis: TelegramPrivacyEditorBasis?) -> some View {
        Button {
            guard let basis, basis.isCurrent(in: controller) else { validationFailed = true; return }
            exceptionDraft = .init(side: side, basis: basis, staged: setting)
        } label: {
            HStack { Text(side == .allow ? "Всегда разрешать" : "Никогда не разрешать"); Spacer(); Text("\(setting.exceptionPeers(side).count)").foregroundStyle(.secondary); Image(systemName: "chevron.right") }
        }.buttonStyle(.plain).disabled(!enabled).accessibilityIdentifier("telegram.privacy.exceptions.\(side.rawValue)")
    }
    private func relatedRow(_ value: TelegramPrivacyKind) -> some View {
        Section {
            Button { related = value } label: { HStack { Text(value.title); Spacer(); Text(controller.snapshot?.settings[value]?.audience?.title ?? "Особое правило").foregroundStyle(.secondary); Image(systemName: "chevron.right") } }
                .buttonStyle(.plain).disabled(!enabled || activeDraft != nil).accessibilityIdentifier("telegram.privacy.open.\(value.rawValue)")
            if activeDraft != nil { Text("Сохраните или отмените изменения перед переходом.").font(.caption).foregroundStyle(.secondary) }
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
@MainActor func privacyStatus(_ controller: TelegramPrivacyController, kind: TelegramPrivacyKind? = nil, global: Bool = false) -> String {
    let mutation = global ? controller.globalMutationStatus : kind.map { controller.mutationStatus(for: $0) } ?? controller.mutationStatus
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
