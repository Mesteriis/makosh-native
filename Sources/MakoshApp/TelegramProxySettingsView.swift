import SwiftUI
import MakoshTelegram

struct TelegramProxySettingsView: View {
    @ObservedObject var controller: TelegramProxyController
    @Environment(\.dismiss) private var dismiss
    private struct Editor: Identifiable { let id = UUID(); let serverID: UUID?; let context: UUID; let draft: TelegramProxyDraft }
    @State private var editor: Editor?
    @State private var confirmation: TelegramProxyConfirmation?
    private var unavailable: Bool { controller.phase != .idle || controller.isOpening || controller.enabled == nil }
    var body: some View {
        let context = controller.contextID
        VStack(spacing: 0) {
            HStack { Text("Настройки прокси").font(.headline); Spacer(); Button("Готово") { dismiss() } }.padding()
            Form {
                Section {
                    Toggle("Использовать прокси", isOn: Binding(get: { controller.enabled == true }, set: { value in confirmation = controller.prepare(.enabled(value), contextID: context) }))
                        .disabled(unavailable).accessibilityIdentifier("telegram.data.proxy.enabled")
                    Text("Общие настройки для окон Telegram на этом Mac. Пароли и MTProto secret хранятся в Keychain.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Прокси") {
                    ForEach(controller.servers) { server in
                        HStack {
                            Button { confirmation = controller.prepare(.select(server.id), contextID: context) } label: {
                                HStack {
                                    Image(systemName: controller.selected == server.id ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading) { Text("\(server.host):\(server.port)"); Text(server.kind == .socks5 ? "SOCKS5" : "MTProto").font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain).accessibilityLabel("Выбрать \(server.host)")
                            Button("Изменить") { if let draft = controller.draft(for: server.id) { editor = .init(serverID: server.id, context: context, draft: draft) } }
                            Button(role: .destructive) { confirmation = controller.prepare(.remove(server.id), contextID: context) } label: { Image(systemName: "trash") }.accessibilityLabel("Удалить \(server.host)")
                        }
                    }
                    Button("Добавить прокси…") { editor = .init(serverID: nil, context: context, draft: .init()) }.accessibilityIdentifier("telegram.data.proxy.add")
                }.disabled(unavailable)
                if controller.phase == .applying { Section { ProgressView("Применение настроек…") } }
                if controller.isOpening { Section { Text("Дождитесь открытия соединения Telegram.") } }
                if let error = controller.error { Section { Text(error).foregroundStyle(.red) } }
                if let status = controller.status { Section { Text(status).foregroundStyle(.secondary) } }
                Section {
                    Button("Обновить", action: controller.open).disabled(controller.phase == .applying).accessibilityIdentifier("telegram.data.proxy.refresh")
                    if controller.phase == .uncertain {
                        Button("Повторно применить сохранённые настройки…") { confirmation = controller.prepareRetry(contextID: context) }.accessibilityIdentifier("telegram.data.proxy.retry")
                    }
                }
            }.formStyle(.grouped)
        }.frame(width: 520, height: 560)
            .onAppear(perform: controller.open).onDisappear(perform: controller.close)
            .sheet(item: $editor) { item in TelegramProxyEditor(controller: controller, serverID: item.serverID, contextID: item.context, draft: item.draft) }
            .alert("Изменить соединение Telegram?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                Button("Отмена", role: .cancel) {}
                Button("Применить") { if let confirmation { controller.confirm(confirmation) } }
            } message: { Text(confirmation?.summary ?? "") }
    }
}
private struct TelegramProxyEditor: View {
    @ObservedObject var controller: TelegramProxyController
    let serverID: UUID?, contextID: UUID
    @State var draft: TelegramProxyDraft
    @State private var confirmation: TelegramProxyConfirmation?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack { Button("Отмена") { dismiss() }; Spacer(); Text(serverID == nil ? "Добавить прокси" : "Изменить прокси").font(.headline); Spacer()
                Button("Сохранить") { confirmation = controller.prepare(serverID.map { .replace($0, draft) } ?? .add(draft), contextID: contextID) }
                    .disabled(controller.contextID != contextID || controller.phase != .idle || controller.isOpening)
                    .accessibilityIdentifier("telegram.data.proxy.save")
            }.padding()
            Form {
                Section {
                    Picker("Тип", selection: $draft.kind) { Text("SOCKS5").tag(TelegramProxyKind.socks5); Text("MTProto").tag(TelegramProxyKind.mtproto) }.pickerStyle(.segmented)
                    TextField("Сервер", text: $draft.host).accessibilityIdentifier("telegram.data.proxy.host")
                    TextField("Порт", text: $draft.port).accessibilityIdentifier("telegram.data.proxy.port")
                }
                Section(draft.kind == .socks5 ? "Учётные данные (необязательно)" : "MTProto secret") {
                    if draft.kind == .socks5 {
                        TextField("Имя пользователя", text: $draft.username).accessibilityIdentifier("telegram.data.proxy.username")
                        SecureField("Пароль", text: $draft.password).accessibilityIdentifier("telegram.data.proxy.password")
                    } else { SecureField("Secret", text: $draft.secret).accessibilityIdentifier("telegram.data.proxy.secret") }
                }
                if let error = controller.error { Section { Text(error).foregroundStyle(.red) } }
                if controller.contextID != contextID { Text("Настройки изменились. Откройте редактор заново.").foregroundStyle(.secondary) }
            }.formStyle(.grouped)
        }.frame(width: 480, height: 410)
            .alert("Сохранить настройки прокси?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
                Button("Отмена", role: .cancel) {}
                Button("Сохранить и применить") {
                    if let confirmation { controller.confirm(confirmation); if controller.phase != .uncertain { dismiss() } }
                }
            } message: { Text(confirmation?.summary ?? "") }
    }
}
