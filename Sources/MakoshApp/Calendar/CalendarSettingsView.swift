import MakoshCalendar
import SwiftUI

/// Settings → Календарь: accounts, calendars, busy groups, working hours, background running.
struct CalendarSettingsView: View {
    @EnvironmentObject private var host: CalendarHost

    var body: some View {
        Group {
            if let model = host.model {
                CalendarSettingsForm(model: model, host: host)
            } else {
                Text("Календарь откроется после подключения к базе данных в главном окне.").padding(24)
            }
        }.frame(minWidth: 620, minHeight: 520)
    }
}

struct CalendarSettingsForm: View {
    @ObservedObject var model: CalendarWorkspaceModel
    @ObservedObject var host: CalendarHost
    @State private var page = "Учётные записи"
    @State private var addingCalDAV = false
    @State private var addingLink = false
    @State private var newGroup = ""
    @State private var membership: [UUID: Set<UUID>] = [:]
    @State private var groups: [CalendarGroup] = []
    @State private var loginItem = LoginItemSetting.isEnabled
    @State private var loginError: String?
    @State private var disconnecting: CalendarAccount?

    var body: some View {
        VStack(spacing: 16) {
            WorkspaceSettingsTabs(titles: ["Учётные записи", "Календари", "Группы занятости", "Рабочий день", "Фон"], selection: $page)
            Form {
                if page == "Учётные записи" { accounts }
                if page == "Календари" { calendars }
                if page == "Группы занятости" { groupSection }
                if page == "Рабочий день" { workingHours }
                if page == "Фон" {
                    Section("Фон") {
                        Text(
                            "Makosh продолжает обновлять календари, плашки «Занято» и напоминания при закрытом окне. Если приложение завершено, плашки не обновляются."
                        )
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Toggle("Открывать Makosh при входе", isOn: $loginItem)
                            .onChange(of: loginItem) { _, value in
                                do { try LoginItemSetting.set(value) } catch {
                                    loginError = "macOS не дал изменить объекты входа."
                                    loginItem = LoginItemSetting.isEnabled
                                }
                            }.accessibilityIdentifier("calendar.settings.loginItem")
                        if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                        MakoshPicker(
                            "Обход календарей",
                            selection: Binding(
                                get: { model.snapshot?.preferences.pollSeconds ?? 120 },
                                set: { value in
                                    _Concurrency.Task { await model.savePreferences { $0.pollSeconds = value } }
                                })
                        ) {
                            Text("Каждую минуту").tag(60)
                            Text("Каждые 2 минуты").tag(120)
                            Text("Каждые 5 минут").tag(300)
                        }
                        LabeledContent("Плашки ставятся вперёд на", value: "\(model.snapshot?.preferences.horizonDays ?? 90) дней")
                    }
                }
            }
            .formStyle(WorkspaceFormStyle())
        }
        .onAppear(perform: loadGroups)
        .onChange(of: model.snapshot?.collections) { _, _ in loadGroups() }
        .sheet(isPresented: $addingCalDAV) { CalendarAddCalDAVSheet(model: model, host: host).makoshAppearance() }
        .sheet(isPresented: $addingLink) { CalendarAddLinkSheet(model: model).makoshAppearance() }
        .sheet(isPresented: Binding(get: { model.groupPreview != nil }, set: { if !$0 { model.cancelGroupChange() } })) {
            if let preview = model.groupPreview { CalendarGroupPreviewSheet(model: model, preview: preview).makoshAppearance() }
        }
        .alert(
            "Отключить «\(disconnecting?.name ?? "")»?",
            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } })
        ) {
            Button("Отключить", role: .destructive) {
                if let account = disconnecting { _Concurrency.Task { await model.disconnect(accountID: account.id) } }
                disconnecting = nil
            }
            Button("Отмена", role: .cancel) { disconnecting = nil }
        } message: {
            Text("Плашки «Занято» этой учётной записи будут убраны, пока доступ ещё есть. История событий остаётся в Makosh.")
        }
        .alert("Календарь", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Понятно", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var accounts: some View {
        Section("Учётные записи") {
            ForEach(model.snapshot?.accounts.filter { $0.state != .disabled } ?? []) { account in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: Self.symbol(account.kind))
                        Text(account.name)
                        Spacer()
                        Text(Self.state(account.state)).font(.caption).foregroundStyle(
                            account.state == .connected ? Color.secondary : Color.orange)
                        if account.kind == .google, account.state == .needsSignIn {
                            Button("Войти снова") { _Concurrency.Task { await model.reauthorize(accountID: account.id) } }
                        }
                        if account.kind != .local {
                            Button("Отключить") { disconnecting = account }.accessibilityIdentifier("calendar.settings.disconnect")
                        }
                    }
                    if account.state == .adminBlocked {
                        Text(
                            "Администратор Google Workspace запретил Makosh доступ к этому аккаунту. Попросите администратора разрешить приложение с идентификатором \(host.googleClientID ?? "—")."
                        ).font(.caption).foregroundStyle(.orange).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if account.kind == .caldav, account.serverSchedules == false {
                        Text("Сервер не рассылает приглашения сам: участники сохранятся только в Makosh.").font(.caption).foregroundStyle(
                            .secondary)
                    }
                }
            }
            HStack {
                Button("Добавить Google") { _Concurrency.Task { await model.addGoogle() } }
                    .disabled(model.snapshot?.googleAvailable != true).accessibilityIdentifier("calendar.settings.addGoogle")
                Button("Добавить CalDAV…") { addingCalDAV = true }.accessibilityIdentifier("calendar.settings.addCalDAV")
                Button("Добавить по ссылке…") { addingLink = true }.accessibilityIdentifier("calendar.settings.addLink")
            }
            if model.snapshot?.googleAvailable != true {
                Text("Вход Google не настроен в этой сборке.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var calendars: some View {
        Section("Календари") {
            ForEach(
                model.snapshot?.collections.filter { c in model.snapshot?.accounts.first { $0.id == c.accountID }?.state != .disabled }
                    ?? []
            ) {
                collection in
                HStack {
                    Menu {
                        ForEach(CalendarStyle.palette, id: \.self) { hex in
                            Button {
                                _Concurrency.Task { await model.setColor(collectionID: collection.id, hex) }
                            } label: {
                                Label(hex, systemImage: "circle.fill")
                            }
                        }
                    } label: {
                        Circle().fill(CalendarStyle.color(collection.color)).frame(width: 12, height: 12)
                    }.menuStyle(.borderlessButton).fixedSize()
                    Text(collection.name)
                    if collection.access == .read { Text("только чтение").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    MakoshPicker(
                        "Напоминание",
                        selection: Binding(
                            get: { collection.defaultReminderMinutes },
                            set: { value in
                                _Concurrency.Task { await model.setDefaultReminder(collectionID: collection.id, minutes: value) }
                            })
                    ) {
                        ForEach([0, 5, 10, 15, 30, 60], id: \.self) { Text($0 == 0 ? "в начале" : "за \($0) мин").tag($0) }
                    }.labelsHidden().fixedSize()
                }
            }
        }
    }

    private var groupSection: some View {
        Section("Группы занятости") {
            Text(
                "Событие в календаре группы даёт плашку «Занято» во всех остальных её календарях. Календарь может входить в несколько групп."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach($groups) { $group in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom) {
                        WorkspaceLabeledField("Название группы") { TextField("Название группы", text: $group.name) }
                        Button(role: .destructive) {
                            groups.removeAll { $0.id == group.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(
                        model.snapshot?.collections.filter { c in
                            model.snapshot?.accounts.first { $0.id == c.accountID }?.state != .disabled
                        } ?? []
                    ) {
                        collection in
                        Toggle(
                            collection.name,
                            isOn: Binding(
                                get: { membership[collection.id, default: []].contains(group.id) },
                                set: { on in
                                    if on {
                                        membership[collection.id, default: []].insert(group.id)
                                    } else {
                                        membership[collection.id, default: []].remove(group.id)
                                    }
                                })
                        ).padding(.leading, 12)
                    }
                }
            }
            HStack {
                TextField("Новая группа", text: $newGroup)
                Button("Добавить") {
                    groups.append(CalendarGroup(name: newGroup.trimmingCharacters(in: .whitespaces)))
                    newGroup = ""
                }.disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Проверить и применить…") {
                    let collections = (model.snapshot?.collections ?? []).map { collection -> CalendarCollection in
                        var value = collection
                        value.groupIDs = membership[collection.id] ?? []
                        return value
                    }
                    _Concurrency.Task { await model.stage(collections: collections, groups: groups) }
                }.accessibilityIdentifier("calendar.settings.applyGroups")
            }
        }
    }

    private var workingHours: some View {
        Section("Рабочий день") {
            Text("Только подсветка в виде календаря: занятости он не создаёт.").font(.caption).foregroundStyle(.secondary)
            ForEach(model.snapshot?.accounts.filter { $0.state != .disabled } ?? []) { account in
                DisclosureGroup(account.name) {
                    ForEach(1...7, id: \.self) { weekday in
                        CalendarWorkingDayRow(weekday: weekday, range: account.workingHours.days[weekday]?.first) { range in
                            var hours = account.workingHours
                            hours.days[weekday] = range.map { [$0] }
                            _Concurrency.Task { await model.setWorkingHours(accountID: account.id, hours) }
                        }
                    }
                }
            }
        }
    }

    private func loadGroups() {
        groups = model.snapshot?.groups ?? []
        membership = Dictionary(uniqueKeysWithValues: (model.snapshot?.collections ?? []).map { ($0.id, $0.groupIDs) })
    }

    static func symbol(_ kind: CalendarAccountKind) -> String {
        switch kind {
        case .local: "internaldrive"
        case .google: "globe"
        case .caldav: "server.rack"
        case .subscription: "link"
        }
    }

    static func state(_ state: CalendarAccountState) -> String {
        switch state {
        case .connected: "подключено"
        case .needsSignIn: "нужен вход"
        case .adminBlocked: "запрещено администратором"
        case .unreachable: "сервер недоступен"
        case .disabled: "отключено"
        }
    }
}

/// One weekday of an account's working hours: on/off and a from–to range.
struct CalendarWorkingDayRow: View {
    let weekday: Int
    let range: ClosedRange<Int>?
    var change: (ClosedRange<Int>?) -> Void

    var body: some View {
        let names = ["", "Понедельник", "Вторник", "Среда", "Четверг", "Пятница", "Суббота", "Воскресенье"]
        HStack {
            Toggle(names[weekday], isOn: Binding(get: { range != nil }, set: { change($0 ? 540...1080 : nil) }))
                .frame(width: CalendarStyle.workingDayLabelWidth, alignment: .leading)
            Spacer()
            if let range {
                WorkspaceStepper(
                    "с \(Self.time(range.lowerBound))",
                    value: Binding(get: { range.lowerBound }, set: { change(min($0, range.upperBound - 30)...range.upperBound) }),
                    in: 0...1410, step: 30
                ).fixedSize()
                WorkspaceStepper(
                    "до \(Self.time(range.upperBound))",
                    value: Binding(get: { range.upperBound }, set: { change(range.lowerBound...max($0, range.lowerBound + 30)) }),
                    in: 30...1440, step: 30
                ).fixedSize()
            }
        }
    }

    static func time(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
}

/// A CalDAV account; a mail account fills in the known server and login, the password is separate.
struct CalendarAddCalDAVSheet: View {
    @ObservedObject var model: CalendarWorkspaceModel
    @ObservedObject var host: CalendarHost
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var server = ""
    @State private var login = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Календарь CalDAV").font(.title2.bold())
            if !host.mailAccounts.isEmpty {
                Menu("Взять из почтовой учётной записи") {
                    ForEach(host.mailAccounts, id: \.email) { account in
                        Button(account.email) {
                            login = account.email
                            if name.isEmpty { name = account.email }
                            if let url = CalDAVProviders.suggestion(email: account.email, imapHost: account.imapHost) {
                                server = url.absoluteString
                            }
                        }
                    }
                }.fixedSize()
            }
            TextField("Название", text: $name).textFieldStyle(WorkspaceTextFieldStyle())
            TextField("Сервер (https://caldav.yandex.ru)", text: $server).textFieldStyle(WorkspaceTextFieldStyle()).accessibilityIdentifier(
                "calendar.caldav.server")
            TextField("Логин", text: $login).textFieldStyle(WorkspaceTextFieldStyle())
            SecureField("Пароль приложения", text: $password).textFieldStyle(WorkspaceTextFieldStyle())
            Text("Для Яндекса нужен пароль приложения для календаря (CalDAV): почтовый подходит не всегда.").font(.caption).foregroundStyle(
                .secondary)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Проверяю…" : "Подключить") {
                    guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)) else { return }
                    busy = true
                    _Concurrency.Task {
                        let ok = await model.addCalDAV(name: name.isEmpty ? login : name, server: url, login: login, password: password)
                        busy = false
                        if ok { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(busy || server.isEmpty || login.isEmpty || password.isEmpty)
            }
        }.padding(20).frame(width: 460)
    }
}

/// A read-only calendar by link (ICS or webcal).
struct CalendarAddLinkSheet: View {
    @ObservedObject var model: CalendarWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Календарь по ссылке").font(.title2.bold())
            TextField("Название", text: $name).textFieldStyle(WorkspaceTextFieldStyle())
            TextField("https://… или webcal://…", text: $link).textFieldStyle(WorkspaceTextFieldStyle())
            Text("Только чтение: Makosh не пишет в него, но его события могут давать «Занято» в группе.").font(.caption).foregroundStyle(
                .secondary)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Подписаться") {
                    guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return }
                    _Concurrency.Task {
                        if await model.addSubscription(name: name.isEmpty ? (url.host ?? "Календарь") : name, url: url) { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).disabled(link.isEmpty)
            }
        }.padding(20).frame(width: 460)
    }
}
