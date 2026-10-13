import SwiftUI
import MakoshTelegram

extension TelegramNotificationCategory {
    var title: String { switch self { case .personal: "Личные чаты"; case .groups: "Группы"; case .channels: "Каналы" } }
}

struct TelegramNotificationSettingsView: View {
    @ObservedObject var controller: TelegramNotificationController
    @EnvironmentObject private var system: TelegramSystemNotifications
    var chats: [TelegramChat] = []
    var synthetic = false
    private struct CategoryChoice: Identifiable { let id = UUID(); let category: TelegramNotificationCategory; let context: UUID }
    @State private var category: CategoryChoice?
    private struct PeerChoice: Identifiable { let id: Int64; let title: String; let context: UUID }
    @State private var peer: PeerChoice?
    @State private var resetContext: UUID?
    private func binding(_ key: WritableKeyPath<TelegramNotificationPreferences, Bool>, context: UUID) -> Binding<Bool> {
        .init(get: { controller.preferences[keyPath: key] }, set: { value in
            var p = controller.preferences; p[keyPath: key] = value; controller.update(p, contextID: context)
        })
    }
    var body: some View {
        let context = controller.contextID
        Form {
            Section("Системные уведомления") {
                switch system.authorization {
                case .notDetermined:
                    Button("Разрешить уведомления macOS", action: system.requestAuthorization)
                        .disabled(system.requesting).accessibilityIdentifier("telegram.notifications.authorize")
                case .denied:
                    Text("Уведомления выключены в macOS.").foregroundStyle(.secondary)
                    Button("Открыть настройки macOS", action: system.openSystemSettings)
                        .accessibilityIdentifier("telegram.notifications.systemSettings")
                default: Text("Уведомления разрешены в macOS.")
                }
                if let status = system.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = controller.error { Section { Text(error).foregroundStyle(.red) } }
            if let warning = controller.deliveryWarning { Section { Text(warning).foregroundStyle(.secondary) } }
            Section("Уведомления и звуки") {
                Toggle("Показывать уведомления", isOn: binding(\.enabled, context: context)).accessibilityIdentifier("telegram.notifications.enabled")
                Toggle("Предпросмотр сообщений", isOn: binding(\.previews, context: context)).accessibilityIdentifier("telegram.notifications.previews")
                Picker("Звук", selection: Binding(get: { controller.preferences.sound }, set: { value in
                    var p = controller.preferences; p.sound = value; controller.update(p, contextID: context)
                })) {
                    Text("Системный").tag(TelegramNotificationSound.system)
                    Text("Без звука").tag(TelegramNotificationSound.none)
                }.accessibilityIdentifier("telegram.notifications.sound")
                Toggle("Привлекать внимание значком Dock", isOn: binding(\.bounce, context: context))
                Toggle("Не показывать при активном окне Макоша", isOn: binding(\.suppressWhileActive, context: context))
                    .accessibilityIdentifier("telegram.notifications.suppressActive")
                Menu("Приостановить уведомления") {
                    ForEach([30,60,480], id: \.self) { minutes in
                        Button(minutes == 30 ? "На 30 минут" : minutes == 60 ? "На час" : "На 8 часов") {
                            var p = controller.preferences; p.snoozeUntil = Date().addingTimeInterval(Double(minutes * 60))
                            controller.update(p, contextID: context)
                        }
                    }
                    Button("Возобновить") { var p = controller.preferences; p.snoozeUntil = nil; controller.update(p, contextID: context) }
                }.accessibilityIdentifier("telegram.notifications.snooze")
                if let until = controller.preferences.snoozeUntil {
                    TimelineView(.periodic(from: .now, by: 1)) { time in
                        Text(until > time.date ? "Приостановлено до \(until.formatted(date: .omitted, time: .shortened))" : "Уведомления возобновлены")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.disabled(controller.error != nil)
            Section("Чаты") {
                ForEach(TelegramNotificationCategory.allCases) { item in
                    Button { category = .init(category: item, context: context) } label: {
                        HStack { Text(item.title); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                    }.buttonStyle(.plain).accessibilityIdentifier("telegram.notifications.category.\(item.rawValue)")
                }
                Text("Настройки показа действуют на этом Mac. Ограничения, заданные в Telegram, сохраняются. Исключения для отдельных чатов доступны в их карточках.")
                    .font(.caption).foregroundStyle(.secondary)
            }.disabled(controller.error != nil)
            if !controller.preferences.peers.isEmpty {
                Section("Исключения") {
                    ForEach(controller.preferences.peers.keys.sorted(), id: \.self) { id in
                        let title = chats.first { $0.id == id }?.title ?? "Чат \(id)"
                        Button(title) { peer = .init(id: id, title: title, context: context) }
                    }
                }
            }
            Section("Счётчик на значке Dock") {
                Toggle("Показывать счётчик", isOn: binding(\.badgeEnabled, context: context)).accessibilityIdentifier("telegram.notifications.badge")
                Group {
                    Toggle("Учитывать группы", isOn: binding(\.badgeGroups, context: context))
                    Toggle("Учитывать каналы", isOn: binding(\.badgeChannels, context: context))
                    Toggle("Считать сообщения вместо чатов", isOn: binding(\.countMessages, context: context))
                }.disabled(!controller.preferences.badgeEnabled)
            }.disabled(controller.error != nil)
            Section {
                Button("Сбросить настройки уведомлений…") { resetContext = context }.accessibilityIdentifier("telegram.notifications.reset")
            }
            #if DEBUG
            if synthetic {
                Section("Синтетическая проверка") {
                    Button("Создать синтетическое входящее") { controller.sendSyntheticNotification() }
                        .accessibilityIdentifier("telegram.notifications.synthetic")
                    if let delivery = controller.delivery {
                        Text(delivery.title).font(.headline)
                        Text(delivery.body).accessibilityIdentifier("telegram.notifications.synthetic.body")
                        Button("Проверить системную доставку", action: system.verifySyntheticDelivery)
                            .accessibilityIdentifier("telegram.notifications.synthetic.verify")
                        Button("Открыть чат из проверочного уведомления") { controller.activate(identifier: delivery.id) }
                            .accessibilityIdentifier("telegram.notifications.synthetic.open")
                    }
                    if let receipt = system.syntheticSystemDelivery { Text(receipt).accessibilityIdentifier("telegram.notifications.synthetic.receipt") }
                }
            }
            #endif
        }.formStyle(.grouped)
            .sheet(item: $category) { item in TelegramNotificationRuleEditor(controller: controller, scope: .category(item.category), title: item.category.title, contextID: item.context) }
            .sheet(item: $peer) { item in TelegramNotificationRuleEditor(controller: controller, scope: .peer(item.id), title: item.title, contextID: item.context) }
            .alert("Сбросить настройки на этом Mac?", isPresented: Binding(get: { resetContext != nil }, set: { if !$0 { resetContext = nil } })) {
                Button("Отмена", role: .cancel) {}
                Button("Сбросить", role: .destructive) { if let resetContext { controller.reset(contextID: resetContext) } }
            } message: { Text("Локальные настройки и исключения вернутся к исходным значениям. Настройки Telegram на других устройствах сохранятся.") }
    }
}

struct TelegramNotificationRuleEditor: View {
    enum Scope { case category(TelegramNotificationCategory), peer(Int64) }
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: TelegramNotificationController
    let scope: Scope
    let title: String
    private let context: UUID
    init(controller: TelegramNotificationController, scope: Scope, title: String, contextID: UUID) {
        self.controller = controller; self.scope = scope; self.title = title; context = contextID
    }
    private var rule: TelegramNotificationRule {
        switch scope { case let .category(value): controller.preferences.categories[value] ?? .init()
        case let .peer(value): controller.preferences.peers[value] ?? .init() }
    }
    private func update(_ value: TelegramNotificationRule?) {
        var p = controller.preferences
        switch scope { case let .category(key): p.categories[key] = value; case let .peer(key): p.peers[key] = value }
        controller.update(p, contextID: context)
    }
    private func boolBinding(_ key: WritableKeyPath<TelegramNotificationRule, Bool?>) -> Binding<Int> {
        .init(get: { rule[keyPath: key].map { $0 ? 1 : 0 } ?? -1 }, set: { raw in
            var value = rule; value[keyPath: key] = raw == -1 ? nil : raw == 1; update(value)
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(title).font(.headline).lineLimit(1); Spacer(); Button("Готово") { dismiss() } }.padding()
            Divider()
            if context != controller.contextID { ContentUnavailableView("Аккаунт изменился", systemImage: "person.crop.circle.badge.exclamationmark") }
            else {
                Form {
                    Section("На этом Mac") {
                        Picker("Уведомления", selection: boolBinding(\.enabled)) {
                            Text("По общим настройкам").tag(-1); Text("Включены").tag(1); Text("Выключены").tag(0)
                        }.accessibilityIdentifier("telegram.notifications.rule.enabled")
                        Picker("Предпросмотр", selection: boolBinding(\.previews)) {
                            Text("По общим настройкам").tag(-1); Text("Показывать").tag(1); Text("Скрывать").tag(0)
                        }.accessibilityIdentifier("telegram.notifications.rule.previews")
                        Picker("Звук", selection: Binding(get: { rule.sound?.rawValue ?? "inherit" }, set: { raw in
                            var value = rule; value.sound = TelegramNotificationSound(rawValue: raw); update(value)
                        })) {
                            Text("По общим настройкам").tag("inherit"); Text("Системный").tag("system"); Text("Без звука").tag("none")
                        }
                        Text("Общее выключение уведомлений и предпросмотра действует для всех чатов. Серверные ограничения Telegram также учитываются.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Убрать исключение") { update(nil) }.accessibilityIdentifier("telegram.notifications.rule.reset")
                    }
                }.formStyle(.grouped).disabled(controller.error != nil)
            }
        }.frame(width: 480, height: 360)
    }
}

struct TelegramNotificationPeerButton: View {
    @ObservedObject var controller: TelegramNotificationController
    let peerID: Int64
    let title: String
    let isCurrent: () -> Bool
    private struct Presentation: Identifiable { let id = UUID(); let context: UUID }
    @State private var presentation: Presentation?
    var body: some View {
        Button("Уведомления") {
            guard isCurrent() else { return }
            presentation = .init(context: controller.contextID)
        }.accessibilityIdentifier("telegram.profile.notifications")
            .sheet(item: $presentation) { item in TelegramNotificationRuleEditor(controller: controller, scope: .peer(peerID), title: title, contextID: item.context) }
    }
}
