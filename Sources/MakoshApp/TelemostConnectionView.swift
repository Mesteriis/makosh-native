import SwiftUI
import MakoshTelemost

struct TelemostConnectionView: View {
    @ObservedObject var model: TelemostWorkspaceModel
    let configuration: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var clientID = ""
    @State private var code = ""
    @State private var create = false
    @State private var update = false
    @State private var browser = TelemostBrowserAuthorization()
    @State private var loginTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(configuration ? "Аккаунт API Телемоста" : (model.selectedAccount?.name ?? "Аккаунт")).font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            if configuration {
                Text("Нужны доступный организации API и собственное OAuth-приложение Яндекса. Client ID — публичный идентификатор, не пароль.").foregroundStyle(.secondary)
                TextField("Название в Макоше", text: $name).textFieldStyle(.roundedBorder)
                TextField("Собственный Client ID · 32 hex", text: $clientID).textFieldStyle(.roundedBorder)
                Text("Callback: org.makosh.desktop.telemost://oauth/callback").font(.caption).textSelection(.enabled)
                Text("Чтение — обязательно"); Toggle("Создание встреч", isOn: $create); Toggle("Изменение зала ожидания", isOn: $update)
                Button("Добавить аккаунт") { Task { var scopes: Set<TelemostCapability> = [.read]; if create { scopes.insert(.create) }; if update { scopes.insert(.update) }; await model.addAccount(name: name, clientID: clientID, capabilities: scopes); if model.error == nil { dismiss() } } }.disabled(model.busy || name.isEmpty || clientID.count != 32)
            } else {
                Text(model.connection.title).foregroundStyle(.secondary)
                if let grant = model.grant {
                    Text("Подтвердите проверенный аккаунт: \(grant.principal.login)").font(.headline)
                    Text("ID: \(grant.principal.userID)").font(.caption).textSelection(.enabled)
                    Text("Разрешения: \(grant.token.capabilities.map(\.rawValue).sorted().joined(separator: ", "))")
                    Button("Подтвердить аккаунт") { Task { await model.confirmAuthorization() } }.disabled(model.busy)
                } else {
                    HStack {
                        Button("Войти в браузере") {
                            guard !model.isSynthetic, let window = NSApp.keyWindow else { model.error = "В QA вход и браузер отключены."; return }
                            loginTask = Task {
                                await model.beginAuthorization(mode: .browserCallback)
                                guard let request = model.authorization else { return }
                                do { let callback = try await browser.authenticate(request, window: window); if !Task.isCancelled { await model.completeAuthorization(callback: callback) } }
                                catch { await model.cancelAuthorization() }
                            }
                        }.disabled(model.busy || model.authorization != nil || model.isSynthetic)
                        Button("Войти по коду") { Task { await model.beginAuthorization(mode: .manualCode) } }.disabled(model.busy || model.authorization != nil || model.isSynthetic)
                    }
                    if let request = model.authorization, request.mode == .manualCode {
                        Button("Открыть Яндекс OAuth") { if !model.isSynthetic { _ = NSWorkspace.shared.open(request.authURL) } }
                        TextField("Код подтверждения", text: $code).textFieldStyle(.roundedBorder)
                        Button("Проверить код") { let value = code; code = ""; Task { await model.completeAuthorization(code: value) } }.disabled(model.busy || code.isEmpty)
                    }
                    if model.authorization != nil { Button("Отменить вход") { loginTask?.cancel(); browser.cancel(); Task { await model.cancelAuthorization() } } }
                }
                HStack { Button("Открыть сохранённый доступ") { Task { await model.connect() } }.disabled(model.busy || model.authorization != nil); Button("Отключить локально") { Task { await model.disconnect() } }.disabled(model.busy) }
                Text("Отключение сохраняет историю и ключи. После истечения доступа нужен явный повторный вход; автоматического обновления токена нет.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
        }.padding(24).frame(width: 600)
        .onDisappear { loginTask?.cancel(); browser.cancel(); Task { await model.cancelAuthorization() } }
    }
}
