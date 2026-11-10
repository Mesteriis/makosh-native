import AppKit
import Contacts
import Foundation
import MakoshOSINT
import MakoshPersons
import SwiftUI

/// Pure rules the settings screen shows.
enum PersonsSettingsRules {
    static let pollIntervals = [300, 600, 1800, 3600]

    /// Both the macOS book and an iCloud CardDAV book accept the address book: iCloud gets every card twice.
    static func warnsDoubleICloud(books: [PersonBook]) -> Bool {
        let live = books.filter { $0.state != .disabled && $0.acceptsAddressBook }
        let mac = live.contains { $0.kind == .macContacts }
        let icloud = live.contains { $0.kind == .carddav && ($0.caldavServer?.host ?? "").lowercased().hasSuffix("icloud.com") }
        return mac && icloud
    }

    static let contactsPrivacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!
}

struct PersonsSettingsView: View {
    @EnvironmentObject private var host: PersonsHost

    var body: some View {
        Group {
            if let model = host.model {
                PersonsSettingsForm(model: model, host: host)
            } else {
                Text(host.failure ?? "Персоны откроются после подключения к базе данных в главном окне.").padding(24)
            }
        }.frame(minWidth: 640, minHeight: 540)
    }
}

struct PersonsSettingsForm: View {
    @ObservedObject var model: PersonsWorkspaceModel
    @ObservedObject var host: PersonsHost
    @State private var page = "Книги"
    @State private var addingCardDAV = false
    @State private var disconnecting: PersonBook?
    @State private var newStopDomain = ""
    @State private var newRolePart = ""
    @State private var macAccess = MacContactsAdapter.authorizationStatus
    @State private var connectingGoogle = false

    private var books: [PersonBook] { model.snapshot?.books ?? [] }
    private var preferences: PersonsPreferences { model.snapshot?.preferences ?? PersonsPreferences() }
    private var macBook: PersonBook? { books.first { $0.kind == .macContacts } }

    var body: some View {
        VStack(spacing: 16) {
            WorkspaceSettingsTabs(titles: ["Книги", "Организации", "Обход", "OSINT", "Открытые попытки"], selection: $page)
            Form {
                if page == "Книги" {
                    booksSection
                    macSection
                }
                if page == "Организации" { organizationSection }
                if page == "Обход" { collectionSection }
                if page == "Открытые попытки" { attemptsSection }
                if page == "OSINT", let osint = host.osintModel { OSINTSettingsSection(osint: osint) }
            }.formStyle(WorkspaceFormStyle())
        }
        .sheet(isPresented: $addingCardDAV) { CardDAVBookSheet(model: model, host: host).makoshAppearance() }
        .alert(
            "Отключить «\(disconnecting?.name ?? "")»?",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })
        ) {
            Button("Отключить", role: .destructive) {
                if let book = disconnecting { _Concurrency.Task { await model.removeBook(id: book.id) } }
                disconnecting = nil
            }
            Button("Отмена", role: .cancel) { disconnecting = nil }
        } message: {
            Text("Пароль учётной записи будет удалён. Персоны и их история остаются в Makosh; карточки во внешней книге не трогаются.")
        }
        .alert("Персоны", isPresented: Binding(get: { model.error != nil && !addingCardDAV }, set: { if !$0 { model.error = nil } })) {
            Button("Понятно", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    // MARK: Books and channels

    private var booksSection: some View {
        Section("Учётные записи и книги") {
            if books.isEmpty { Text("Каналы появятся здесь после подключения учётных записей в главном окне.").foregroundStyle(.secondary) }
            ForEach(books.filter { $0.kind != .macContacts }) { book in bookRow(book) }
            HStack {
                Button("Подключить CardDAV…") { addingCardDAV = true }.accessibilityIdentifier("persons.settings.addCardDAV")
                Button(connectingGoogle ? "Жду Google…" : "Подключить Google…") {
                    connectingGoogle = true
                    _Concurrency.Task {
                        _ = await model.connectGoogle(loginHint: nil)
                        connectingGoogle = false
                    }
                }
                .disabled(connectingGoogle || model.snapshot?.googleAvailable != true).accessibilityIdentifier("persons.settings.addGoogle")
            }
            if model.snapshot?.googleAvailable != true {
                Text("Вход Google не настроен в этой сборке.").font(.caption).foregroundStyle(.secondary)
            }
            if PersonsSettingsRules.warnsDoubleICloud(books: books) {
                Label(
                    "Включены и книга macOS, и CardDAV iCloud: каждая карточка попадёт в iCloud дважды. Оставьте приём адресной книги в одной из них.",
                    systemImage: "exclamationmark.triangle"
                ).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bookRow(_ book: PersonBook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: Self.symbol(book.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.name)
                    Text(PersonsBookText.kind(book.kind)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(PersonsBookText.state(book.state)).font(.caption).foregroundStyle(
                    book.state == .connected ? Color.secondary : Color.orange)
                if book.state == .needsSignIn || book.state == .unreachable {
                    Button(book.kind == .googleContacts && book.state == .needsSignIn ? "Повторный вход" : "Повторить") {
                        _Concurrency.Task {
                            if book.kind == .googleContacts, book.state == .needsSignIn {
                                _ = await model.connectGoogle(loginHint: book.name)
                            } else {
                                await model.reconnect(bookID: book.id)
                            }
                        }
                    }
                }
                if book.kind == .googleContacts, book.state == .needsSignIn, model.snapshot?.googleAvailable == true {
                    Button("Разрешить контакты") { _Concurrency.Task { _ = await model.connectGoogle(loginHint: book.name) } }
                }
                if book.kind.isBook, book.kind != .telegram {
                    Button("Отключить") { disconnecting = book }.accessibilityIdentifier("persons.settings.disconnect")
                }
            }
            if let failure = book.lastError {
                Text(PersonsWorkspaceModel.describe(failure)).font(.caption).foregroundStyle(.orange).fixedSize(
                    horizontal: false, vertical: true)
            }
            HStack(spacing: 18) {
                if book.kind.hasConversations {
                    Toggle(
                        "Собирать собеседников",
                        isOn: Binding(
                            get: { book.collectConversations },
                            set: { value in _Concurrency.Task { await model.setBookOptions(id: book.id, collectConversations: value) } })
                    ).accessibilityIdentifier("persons.settings.collect.\(book.kind.rawValue)")
                }
                if book.kind.isBook {
                    Toggle(
                        "Читать адресную книгу",
                        isOn: Binding(
                            get: { book.readBook },
                            set: { value in _Concurrency.Task { await model.setBookOptions(id: book.id, readBook: value) } }))
                    Toggle(
                        "Её контакты — моя адресная книга",
                        isOn: Binding(
                            get: { book.isAddressBookSource },
                            set: { value in _Concurrency.Task { await model.setBookOptions(id: book.id, isAddressBookSource: value) } })
                    ).accessibilityIdentifier("persons.settings.source")
                    Toggle(
                        "Принимать адресную книгу",
                        isOn: Binding(
                            get: { book.acceptsAddressBook },
                            set: { value in _Concurrency.Task { await model.setBookOptions(id: book.id, acceptsAddressBook: value) } }))
                    if OSINTAutoSources.allowsAutomaticEnrichment(service: book.source.service) {
                        Toggle(
                            "Обогащать автоматически",
                            isOn: Binding(
                                get: { book.enrichAutomatically },
                                set: { value in _Concurrency.Task { await model.setBookOptions(id: book.id, enrichAutomatically: value) } })
                        ).help("Новые люди из этой книги уходят в OSINT-модуль, только пока он включён и установлен.")
                            .accessibilityIdentifier("persons.settings.enrich")
                    }
                }
            }.toggleStyle(WorkspaceToggleStyle(checkbox: true)).font(.callout)
        }.padding(.vertical, 2)
    }

    // MARK: macOS Contacts

    private var macSection: some View {
        Section("Контакты macOS") {
            Toggle(
                "Книга macOS",
                isOn: Binding(
                    get: { macBook != nil && macBook?.state != .disabled },
                    set: { value in _Concurrency.Task { await toggleMac(value) } })
            ).accessibilityIdentifier("persons.settings.mac")
            if let book = macBook {
                bookRow(book)
            }
            if macAccess == .denied || macAccess == .restricted || macBook?.state == .noAccess {
                HStack {
                    Text("macOS не даёт Makosh доступ к Контактам.").font(.caption).foregroundStyle(.orange)
                    Button("Открыть Настройки системы") { NSWorkspace.shared.open(PersonsSettingsRules.contactsPrivacyURL) }
                }
            }
            Text("Контакты iCloud приходят сюда через системную книгу; отдельный CardDAV iCloud нужен только без неё.").font(.caption)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleMac(_ on: Bool) async {
        if on {
            if MacContactsAdapter.authorizationStatus != .authorized { _ = await MacContactsAdapter.requestAccess() }
            macAccess = MacContactsAdapter.authorizationStatus
            guard macAccess == .authorized else {
                model.error = "macOS не дал доступ к Контактам. Разрешите его в Настройках системы → Конфиденциальность → Контакты."
                return
            }
            _ = await model.connectMacContacts()
        } else if let book = macBook {
            await model.removeBook(id: book.id)
        }
    }

    // MARK: Organizations

    private var organizationSection: some View {
        Section("Организации") {
            Toggle("По полю «компания»", isOn: preference(\.companyRuleEnabled))
            Toggle("По домену почты (не менее двух адресов, кроме публичных почт)", isOn: preference(\.domainRuleEnabled))
            editableList(
                "Стоп-список доменов", items: preferences.extraStopDomains, draft: $newStopDomain, placeholder: "example.com",
                save: { domains in savePreferences { $0.extraStopDomains = domains } })
            editableList(
                "Служебные адреса (локальная часть)", items: preferences.extraRoleLocalParts, draft: $newRolePart, placeholder: "noreply",
                save: { parts in savePreferences { $0.extraRoleLocalParts = parts } })
        }
    }

    private func editableList(
        _ title: String, items: [String], draft: Binding<String>, placeholder: String, save: @escaping ([String]) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout)
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(.callout.monospaced())
                    Spacer()
                    Button {
                        save(items.filter { $0 != item })
                    } label: {
                        Image(systemName: "minus.circle")
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                TextField(placeholder, text: draft).textFieldStyle(WorkspaceTextFieldStyle()).onSubmit {
                    add(items, draft: draft, save: save)
                }
                Button("Добавить") { add(items, draft: draft, save: save) }.disabled(
                    draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add(_ items: [String], draft: Binding<String>, save: ([String]) -> Void) {
        let value = draft.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty, !items.contains(value) else { return }
        save(items + [value])
        draft.wrappedValue = ""
    }

    // MARK: Collection

    private var collectionSection: some View {
        Section("Обход") {
            MakoshPicker(
                "Чтение книг",
                selection: Binding(
                    get: { preferences.pollIntervalSeconds }, set: { value in savePreferences { $0.pollIntervalSeconds = value } })
            ) {
                Text("Каждые 5 минут").tag(300)
                Text("Каждые 10 минут").tag(600)
                Text("Каждые 30 минут").tag(1800)
                Text("Каждый час").tag(3600)
            }
            WorkspaceStepper(
                "Записей за проход: \(preferences.maxWritesPerPass)",
                value: Binding(get: { preferences.maxWritesPerPass }, set: { value in savePreferences { $0.maxWritesPerPass = value } }),
                in: 10...500, step: 10)
            Text("Makosh читает книги и дописывает карточки при закрытом окне. Если приложение завершено, книги не обновляются.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var attemptsSection: some View {
        Section("Открытые попытки") {
            let attempts = model.snapshot?.openAttempts ?? []
            if attempts.isEmpty { Text("Все записи во внешние книги подтверждены.").foregroundStyle(.secondary) }
            ForEach(attempts) { attempt in
                HStack {
                    Text(PersonsBookText.attempt(attempt)).font(.callout)
                    Spacer()
                    if attempt.state == .unknown {
                        Button("Проверить") { _Concurrency.Task { await model.settle(bookID: attempt.bookID) } }
                        Button("Отказаться") { _Concurrency.Task { await model.dismiss(attemptID: attempt.id) } }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private func preference(_ keyPath: WritableKeyPath<PersonsPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { preferences[keyPath: keyPath] }, set: { value in savePreferences { $0[keyPath: keyPath] = value } })
    }

    private func savePreferences(_ change: @escaping (inout PersonsPreferences) -> Void) {
        var value = preferences
        change(&value)
        _Concurrency.Task { await model.savePreferences(value) }
    }

    static func symbol(_ kind: PersonBookKind) -> String {
        switch kind {
        case .telegram: "paperplane"
        case .carddav: "book.closed"
        case .googleContacts: "g.circle"
        case .macContacts: "person.crop.rectangle.stack"
        case .synthetic: "testtube.2"
        case .mail: "envelope"
        case .whatsapp: "message"
        case .teams: "person.3"
        }
    }
}
