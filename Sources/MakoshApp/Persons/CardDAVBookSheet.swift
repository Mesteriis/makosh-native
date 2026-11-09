import Foundation
import MakoshPersons
import SwiftUI

/// Known CardDAV servers by mail domain or IMAP host; the login is the mail address.
enum CardDAVHints {
    static func suggestion(email: String, imapHost: String) -> (server: URL, login: String)? {
        let domain = email.split(separator: "@").last.map { $0.lowercased() } ?? ""
        let host = imapHost.lowercased()
        let server: String? =
            if domain.hasSuffix("yandex.ru") || domain.hasSuffix("yandex.com") || domain == "ya.ru" || host.hasSuffix("yandex.ru")
                || host.hasSuffix("yandex.com")
            {
                "https://carddav.yandex.ru"
            } else if ["icloud.com", "me.com", "mac.com"].contains(domain) || host.hasSuffix("mail.me.com") || host.hasSuffix("icloud.com")
            {
                "https://contacts.icloud.com"
            } else if domain.hasSuffix("fastmail.com") || domain.hasSuffix("fastmail.fm") || host.hasSuffix("fastmail.com") {
                "https://carddav.fastmail.com"
            } else {
                nil
            }
        guard let server, let url = URL(string: server) else { return nil }
        return (url, email)
    }
}

/// «Подключить CardDAV…»: server, login and an application password; mail accounts fill the server in.
struct CardDAVBookSheet: View {
    @ObservedObject var model: PersonsWorkspaceModel
    @ObservedObject var host: PersonsHost
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var server = ""
    @State private var login = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Адресная книга CardDAV").font(.title2.bold())
            if !host.mailAccounts.isEmpty {
                Menu("Взять из почтовой учётной записи") {
                    ForEach(host.mailAccounts, id: \.email) { account in
                        Button(account.email) {
                            login = account.email
                            if name.isEmpty { name = account.email }
                            if let hint = CardDAVHints.suggestion(email: account.email, imapHost: account.imapHost) {
                                server = hint.server.absoluteString
                            }
                        }
                    }
                }.fixedSize()
            }
            TextField("Название", text: $name).textFieldStyle(.roundedBorder)
            TextField("Сервер (https://carddav.yandex.ru)", text: $server).textFieldStyle(.roundedBorder).accessibilityIdentifier(
                "persons.carddav.server")
            TextField("Логин", text: $login).textFieldStyle(.roundedBorder).accessibilityIdentifier("persons.carddav.login")
            SecureField("Пароль приложения", text: $password).textFieldStyle(.roundedBorder).accessibilityIdentifier(
                "persons.carddav.password")
            Text("Для Яндекса и iCloud нужен пароль приложения; почтовый пароль не подходит. Пароль хранится только в Связке ключей.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Проверяю…" : "Подключить") {
                    guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)) else { return }
                    busy = true
                    model.error = nil
                    _Concurrency.Task {
                        let ok = await model.connectCardDAV(
                            name: name.isEmpty ? login : name, server: url, login: login, password: password)
                        busy = false
                        if ok { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(busy || server.isEmpty || login.isEmpty || password.isEmpty)
                    .accessibilityIdentifier("persons.carddav.connect")
            }
        }.padding(20).frame(width: 460)
    }
}
