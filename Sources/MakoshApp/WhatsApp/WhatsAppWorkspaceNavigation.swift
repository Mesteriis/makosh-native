import MakoshWhatsApp
// Layout adapted from WhatsApp Zen MainView.swift / Components.swift (MIT).
// See LICENSES/WhatsApp-Zen-MIT.txt and docs/reference-interface.md.
import SwiftUI

enum WhatsAppFilter: String, CaseIterable {
    case all = "Все", unread = "Непрочитанные", groups = "Группы", archived = "Архив"
}
@MainActor final class WhatsAppWorkspaceNavigationState: ObservableObject {
    @Published var search = ""
    @Published var filter = WhatsAppFilter.all
    func matches(_ chat: WhatsAppChat, search: Bool = true) -> Bool {
        (filter == .archived ? chat.archived : !chat.archived)
            && (filter != .unread || chat.unread > 0) && (filter != .groups || chat.group)
            && (!search || self.search.isEmpty || chat.name.localizedCaseInsensitiveContains(self.search))
    }
}
struct WhatsAppWorkspaceNavigation: View {
    @ObservedObject var model: WhatsAppWorkspaceModel
    @ObservedObject var navigation: WhatsAppWorkspaceNavigationState
    @State private var adding = false
    @State private var statuses = false
    @State private var accountSettings = false
    @State private var newChat = false
    @State private var name = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                MakoshMenu {
                    Text(model.isSynthetic ? "Синтетическая проверка · без сети" : model.status.label)
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.accounts) { account in
                        MakoshMenuItem(account.name) { Task { await model.selectAccount(account.id) } }
                    }
                    Divider()
                    MakoshMenuItem("Добавить аккаунт") { adding = true }.disabled(model.isSynthetic)
                    MakoshMenuItem("Настройки WhatsApp") { accountSettings = true }
                    if !model.isSynthetic, model.selectedAccountID != nil {
                        if model.status.state != "logged_out" {
                            MakoshMenuItem(model.status.linked ? "Подключено" : "Подключить") { model.connect() }
                                .disabled(model.busy || model.status.linked)
                        }
                        if model.busy || model.status.state != "offline" {
                            MakoshMenuItem("Отключить") { Task { await model.disconnect() } }
                        }
                    }
                    #if DEBUG
                    if model.isSynthetic {
                        MakoshMenuItem("Тестовое окно звонка") { model.calls.preview() }
                        MakoshMenuItem("Показать тестовый QR") { Task { await model.previewPairing() } }
                    }
                    #endif
                    Divider()
                    MakoshMenuItem("Лицензия ядра") {
                        if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses/WhatsApp-Worker-AGPL-3.0.txt") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    MakoshMenuItem("Исходники ядра") {
                        if let url = Bundle.main.url(forResource: "MakoshWhatsAppWorker-Source", withExtension: "tar.gz") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                } label: {
                    Label(
                        model.accounts.first { $0.id == model.selectedAccountID }?.name ?? "Аккаунт WhatsApp",
                        systemImage: "person.crop.circle"
                    )
                    .lineLimit(1)
                }.makoshMenuStyle(.bordered).makoshMenuIndicator(.visible)
                    .accessibilityIdentifier("whatsapp.account.selector")
                MakoshPicker("Раздел", selection: $navigation.filter) {
                    ForEach(WhatsAppFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().fixedSize().accessibilityIdentifier("whatsapp.workspace.filter")
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск чатов", text: $navigation.search).textFieldStyle(.plain)
                        .accessibilityIdentifier("whatsapp.search")
                    if !navigation.search.isEmpty {
                        Button {
                            navigation.search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).accessibilityLabel("Очистить поиск чатов")
                    }
                }.padding(11).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)) }
                Button {
                    statuses = true
                } label: {
                    Image(systemName: "circle.dashed")
                }
                .buttonStyle(.plain).accessibilityLabel("Статусы WhatsApp").disabled(model.selectedAccountID == nil)
                Button {
                    newChat = true
                } label: {
                    Label("Новый чат", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.selectedAccountID == nil)
                .accessibilityIdentifier("whatsapp.workspace.newChat")
            }.padding(.horizontal, 20).frame(height: 64)
            if let error = model.notificationError { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
            if let error = model.archiveError { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
        }.background { WorkspaceBackdrop(intensity: 0.5) }.tint(WorkspaceStyle.accent)
            .sheet(isPresented: $newChat) {
                if let account = model.selectedAccountID {
                    WhatsAppNewChatView(model: model, accountID: account)
                }
            }
            .sheet(isPresented: $accountSettings) {
                VStack {
                    HStack {
                        Spacer()
                        Button("Закрыть") { accountSettings = false }
                    }.padding()
                    WhatsAppSettingsView(model: model)
                }.frame(width: 700, height: 600)
            }
            .sheet(isPresented: $statuses) {
                if let account = model.selectedAccountID {
                    WhatsAppStatusView(worker: model.notificationWorker, accountID: account)
                }
            }
            .sheet(isPresented: $adding) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Добавить WhatsApp").font(.title2.bold())
                    TextField("Название аккаунта", text: $name).textFieldStyle(.roundedBorder)
                    Text("После добавления отсканируйте QR-код в WhatsApp на телефоне.").foregroundStyle(
                        .secondary)
                    HStack {
                        Button("Отмена") { adding = false }
                        Spacer()
                        Button("Добавить и подключить") {
                            Task {
                                if await model.addAccount(name) {
                                    adding = false
                                    name = ""
                                }
                            }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                            .keyboardShortcut(.defaultAction)
                    }
                }.padding(24).frame(width: 420)
            }
            .alert(
                "WhatsApp",
                isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button("Понятно") { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
    }
}
