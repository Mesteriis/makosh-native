import SwiftUI
import MakoshTelegram

enum TelegramGlobalPrivacyPage: String, Identifiable {
    case messages, readTime, giftTypes
    var id: String { rawValue }
    var title: String { switch self { case .messages: "Сообщения"; case .readTime: "Время прочтения"; case .giftTypes: "Типы подарков" } }
}
extension TelegramIncomingMessagePolicy {
    var title: String { switch self { case .everybody: "Все"; case .contactsAndPremium: "Контакты и Premium"; case let .paidStars(amount): "\(amount) Stars за сообщение" } }
}
private extension TelegramGiftKind {
    var title: String { switch self { case .unlimited: "Обычные"; case .limited: "Лимитированные"; case .unique: "Коллекционные"; case .premium: "Подписки Premium" } }
}
private enum MessagePrivacyChoice: String { case everybody, restricted, paid }
private struct GlobalPrivacyDraft: Identifiable {
    let id = UUID()
    let basis: TelegramGlobalPrivacyEditorBasis
    let change: TelegramGlobalPrivacyChange
}

struct TelegramGlobalPrivacyView: View {
    @ObservedObject var controller: TelegramPrivacyController
    let page: TelegramGlobalPrivacyPage
    let synthetic: Bool
    let close: () -> Void
    @State private var draft: GlobalPrivacyDraft?
    @State private var confirmation: GlobalPrivacyDraft?
    @State private var priceText: String?
    @State private var invalidPrice = false
    @State private var validationFailed = false
    @State private var exemptions = false
    private var activeDraft: GlobalPrivacyDraft? { draft.flatMap { $0.basis.isCurrent(in: controller) ? $0 : nil } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Назад", action: close).accessibilityIdentifier("telegram.privacy.global.back")
                Spacer(); Text(page.title).font(.headline); Spacer()
                Button("Обновить") { controller.refresh() }.disabled(controller.mutationStatus == .saving).accessibilityIdentifier("telegram.privacy.global.refresh")
            }.padding()
            Text(validationFailed ? "Не удалось подтвердить изменения. Обновите настройки." : privacyStatus(controller, global: true))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("telegram.privacy.global.status")
            if let original = controller.snapshot?.global, let basis = TelegramGlobalPrivacyEditorBasis(controller: controller) {
                let current = activeDraft?.change.proposed ?? original
                Form {
                    controls(current: current, basis: basis)
                    Section {
                        Button("Сохранить") { confirmation = activeDraft }
                            .disabled(activeDraft == nil || invalidPrice || !basis.isCurrent(in: controller)).accessibilityIdentifier("telegram.privacy.global.save")
                        if activeDraft != nil || invalidPrice { Button("Отменить изменения") { resetDraft() }.accessibilityIdentifier("telegram.privacy.global.discard") }
                    }
                }.formStyle(.grouped).disabled(!basis.isCurrent(in: controller))
            } else { ContentUnavailableView("Настройки недоступны", systemImage: "hand.raised") }
        }.frame(width: 520, height: 630)
        .onChange(of: controller.contextID) { _, _ in resetDraft(); confirmation = nil }
        .onChange(of: controller.snapshot?.accountID) { _, _ in exemptions = false }
        .sheet(isPresented: $exemptions) {
            TelegramPrivacyDetailView(controller: controller, kind: .noPaidMessages, synthetic: synthetic) { exemptions = false }
        }
        .alert("Сохранить настройки приватности?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { request in
            Button("Отмена", role: .cancel) { confirmation = nil }
            Button("Подтвердить") {
                let accepted = request.basis.isCurrent(in: controller) && controller.applyGlobal(request.change, contextID: request.basis.contextID)
                validationFailed = !accepted; if accepted { resetDraft() }; confirmation = nil
            }
        } message: { request in Text((synthetic ? "Симуляция. " : "") + confirmationText(request.change.proposed)) }
    }
    @ViewBuilder private func controls(current: TelegramGlobalPrivacySetting, basis: TelegramGlobalPrivacyEditorBasis) -> some View {
        switch page {
        case .readTime:
            Section {
                Toggle("Скрывать время прочтения", isOn: Binding(get: { current.hideReadTime }, set: { stage(.hideReadTime($0), current: current, basis: basis) }))
                    .accessibilityIdentifier("telegram.privacy.global.hideReadTime")
                Text("Время прочтения скрывается от людей, которым недоступно время вашего последнего посещения.").font(.caption).foregroundStyle(.secondary)
            }
        case .giftTypes:
            Section("Какие подарки можно мне отправлять") {
                ForEach(TelegramGiftKind.allCases) { kind in
                    Toggle(kind.title, isOn: Binding(get: { current.allowsGift(kind) }, set: { stage(.allowGift(kind, $0), current: current, basis: basis) }))
                        .disabled(controller.snapshot?.capabilities?.isPremium != true).accessibilityIdentifier("telegram.privacy.global.gift.\(kind.rawValue)")
                }
                if controller.snapshot?.capabilities?.isPremium != true { Text("Изменение типов подарков доступно с Telegram Premium.").font(.caption).foregroundStyle(.secondary) }
            }
        case .messages: messageControls(current: current, basis: basis)
        }
    }
    @ViewBuilder private func messageControls(current: TelegramGlobalPrivacySetting, basis: TelegramGlobalPrivacyEditorBasis) -> some View {
        let capabilities = controller.snapshot?.capabilities
        let canRestrict = capabilities?.canRestrictIncomingMessages == true
        let canCharge = canRestrict && capabilities?.paidMessagesAvailable == true
        Section("Кто может отправлять мне сообщения") {
            Picker("Входящие сообщения", selection: Binding(get: { choice(current.messagePolicy) }, set: { value in
                priceText = nil; invalidPrice = false
                let policy: TelegramIncomingMessagePolicy
                switch value {
                case .everybody: policy = .everybody
                case .restricted: policy = .contactsAndPremium
                case .paid:
                    if case let .paidStars(amount) = basis.setting.messagePolicy { policy = .paidStars(amount) }
                    else { policy = .paidStars(min(10, max(1, capabilities?.maximumPaidStars ?? 0))) }
                }
                stage(.messagePolicy(policy), current: current, basis: basis)
            })) {
                Text("Все").tag(MessagePrivacyChoice.everybody)
                Text("Контакты и пользователи Premium").tag(MessagePrivacyChoice.restricted).disabled(!canRestrict)
                if capabilities?.paidMessagesAvailable == true || choice(current.messagePolicy) == .paid {
                    Text("Плата за сообщения в Stars").tag(MessagePrivacyChoice.paid).disabled(!canCharge)
                }
            }.pickerStyle(.radioGroup).labelsHidden().accessibilityIdentifier("telegram.privacy.global.messages")
            Text("Режим «Контакты и Premium» ограничивает входящие сообщения от остальных пользователей.").font(.caption).foregroundStyle(.secondary)
            if !canRestrict { Text("Изменение ограничений доступно с Telegram Premium либо при разрешении Telegram для этого аккаунта.").font(.caption).foregroundStyle(.secondary) }
        }
        if case let .paidStars(amount) = current.messagePolicy {
            Section("Плата за одно сообщение") {
                TextField("Stars", text: Binding(get: { priceText ?? String(amount) }, set: { text in
                    priceText = text
                    guard !text.isEmpty, text.utf8.count <= 19, text.utf8.allSatisfy({ (48...57).contains($0) }),
                          let amount = Int64(text), amount > 0, amount <= (capabilities?.maximumPaidStars ?? 0) else { invalidPrice = true; return }
                    invalidPrice = false; stage(.messagePolicy(.paidStars(amount)), current: current, basis: basis)
                })).disabled(!canCharge).accessibilityIdentifier("telegram.privacy.global.stars")
                if invalidPrice { Text("Введите целое число в разрешённом диапазоне.").foregroundStyle(.red) }
                Text("Лимит Telegram: \(capabilities?.maximumPaidStars ?? 0) Stars. Изменение вступит в силу после подтверждения.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Кто может писать без платы") { exemptions = true }.disabled(activeDraft != nil || invalidPrice).accessibilityIdentifier("telegram.privacy.global.exemptions")
                if activeDraft != nil || invalidPrice { Text("Сначала сохраните или отмените изменения платы.").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func choice(_ policy: TelegramIncomingMessagePolicy) -> MessagePrivacyChoice {
        switch policy { case .everybody: .everybody; case .contactsAndPremium: .restricted; case .paidStars: .paid }
    }
    private func stage(_ edit: TelegramGlobalPrivacyEdit, current: TelegramGlobalPrivacySetting, basis: TelegramGlobalPrivacyEditorBasis) {
        guard basis.isCurrent(in: controller) else { validationFailed = true; return }
        guard let next = current.replacing(edit) else { return }
        if next == basis.setting { draft = nil; validationFailed = false; return }
        guard let change = basis.change(to: next, controller: controller) else { validationFailed = true; return }
        draft = .init(basis: basis, change: change); validationFailed = false
    }
    private func resetDraft() { draft = nil; priceText = nil; invalidPrice = false; validationFailed = false }
    private func confirmationText(_ setting: TelegramGlobalPrivacySetting) -> String {
        switch page {
        case .messages: "Входящие сообщения: \(setting.messagePolicy.title)."
        case .readTime: "Скрывать время прочтения: \(setting.hideReadTime ? "да" : "нет")."
        case .giftTypes: "Разрешённые подарки: \(TelegramGiftKind.allCases.filter { setting.allowsGift($0) }.map(\.title).joined(separator: ", "))."
        }
    }
}
