import SwiftUI
import MakoshTeams

struct TeamsConnectionView: View {
    @ObservedObject var model: TeamsWorkspaceModel
    let creating: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var clientID = ""
    @State private var authority = "organizations"
    @State private var readOnly = false
    @State private var method = TeamsAuthorizationMethod.browserPKCE
    @State private var capabilities: Set<TeamsCapability> = [.basicChats]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(creating ? "Добавить Teams" : "Вход и разрешения Teams").font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            Form {
                if creating {
                    TextField("Название аккаунта", text: $name)
                    TextField("Application (client) ID вашего приложения Entra", text: $clientID)
                    TextField("Организация: organizations или tenant ID", text: $authority)
                    Toggle("Только чтение", isOn: $readOnly)
                    Text("Используйте собственную регистрацию public client в Microsoft Entra. Для браузерного входа зарегистрируйте точный loopback path http://127.0.0.1/callback (порт выбирается при входе); для device code — public client flow. Личные Microsoft-аккаунты не поддерживаются.").font(.caption).foregroundStyle(.secondary)
                    Button("Добавить аккаунт") { Task { await model.addAccount(name: name, clientID: clientID, authority: authority, readOnly: readOnly); if model.error == nil { dismiss() } } }.disabled(model.busy || name.isEmpty || clientID.isEmpty).accessibilityIdentifier("teams.account.create")
                } else {
                    Text(model.selectedAccount?.name ?? "Аккаунт не выбран").font(.headline)
                    Picker("Способ входа", selection: $method) { Text("В браузере · PKCE").tag(TeamsAuthorizationMethod.browserPKCE); Text("По коду устройства").tag(TeamsAuthorizationMethod.deviceCode) }.pickerStyle(.menu)
                    Section("Разрешения") {
                        ForEach(TeamsCapability.allCases, id: \.self) { capability in
                            Toggle(teamsCapabilityTitle(capability), isOn: Binding(get: { capabilities.contains(capability) }, set: { enabled in if enabled { capabilities.insert(capability) } else { capabilities.remove(capability) } })).disabled(capability == .basicChats)
                        }
                        Text("Чтение списка участников каналов может требовать согласия администратора. Поиск файла по sharing URL требует Files.ReadWrite даже для скачивания. Разрешения не добавляются автоматически.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Начать вход") { Task { await model.authorize(method: method, capabilities: capabilities.union([.basicChats])) } }.disabled(model.isSynthetic || model.selectedAccountID == nil).accessibilityIdentifier("teams.auth.begin")
                    if let authorization = model.authorization {
                        switch authorization {
                        case .pending: ProgressView("Подготовка входа…")
                        case let .browser(url): Link("Открыть Microsoft для входа", destination: url)
                        case let .device(code, url, expires, _): Text(code).font(.title.monospaced()).textSelection(.enabled); Link("Открыть страницу подтверждения", destination: url); Text("Код действителен до \(expires.formatted(date: .omitted, time: .shortened))").font(.caption)
                        case .ready: Label("Вход завершён", systemImage: "checkmark.circle")
                        case .cancelled: Text("Вход отменён. Предыдущее подключение сохранено.")
                        case let .failed(failure): Text(teamsFailureMessage(failure)).foregroundStyle(.orange)
                        }
                        Button("Отменить вход") { Task { await model.cancelAuthorization() } }.accessibilityIdentifier("teams.auth.cancel")
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(.orange) }
            }.formStyle(.grouped)
        }.padding(20).frame(width: 620, height: creating ? 440 : 680)
    }
}
func teamsCapabilityTitle(_ capability: TeamsCapability) -> String {
    switch capability {
    case .basicChats: "Читать чаты и профиль"
    case .teams: "Видеть команды и каналы"
    case .channelHistory: "Читать сообщения каналов"
    case .channelMembers: "Проверять всех участников каналов"
    case .sendChat: "Отправлять сообщения в чаты"
    case .sendChannel: "Публиковать в каналах"
    case .readFiles: "Читать свои файлы"
    case .readSharedFiles: "Читать доступные общие файлы"
    case .resolveSharedLink: "Находить файлы по sharing URL · Files.ReadWrite"
    case .writeFiles: "Загружать файлы в свой OneDrive"
    case .writeSharedFiles: "Загружать в доступные общие хранилища"
    }
}
