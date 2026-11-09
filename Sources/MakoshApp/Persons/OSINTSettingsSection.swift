import AppKit
import Foundation
import MakoshOSINT
import SwiftUI

/// Settings → Персоны → «OSINT-модуль (flowsint)»: connection, installation, service user, keys, enricher sets, open attempts.
struct OSINTSettingsSection: View {
    @ObservedObject var osint: OSINTWorkspaceModel
    @State private var host = ""
    @State private var port = "22"
    @State private var login = ""
    @State private var password = ""
    @State private var loaded = false
    @State private var enteringServicePassword = false
    @State private var servicePasswordDraft = ""
    @State private var keyBeingSet: String?
    @State private var keyDraft = ""
    @State private var report: OSINTConnectionReport?

    private var settings: OSINTSettings? { osint.snapshot?.settings }
    private var serviceAuthFailed: Bool {
        guard let settings else { return false }
        return OSINTSettingsRules.needsServiceUser(
            settings: settings, lastFailure: osint.snapshot?.lastFailure, lastInstall: osint.snapshot?.lastInstall)
    }

    var body: some View {
        Section("OSINT-модуль (flowsint)") {
            if let settings {
                Toggle(
                    "OSINT-модуль включён",
                    isOn: Binding(get: { settings.enabled }, set: { value in _Concurrency.Task { await osint.setEnabled(value) } })
                ).accessibilityIdentifier("persons.osint.enabled")
                connectionFields(settings)
                installationRows(settings)
                if serviceAuthFailed { serviceUserRows }
                keysRows(settings)
                enricherRows(settings)
                attemptsRows
            } else {
                Text(osint.error ?? "OSINT-модуль откроется вместе с разделом «Персоны».").foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: fill)
        .onChange(of: osint.snapshot?.settings) { _, _ in fill() }
        .sheet(
            isPresented: Binding(get: { osint.pendingFingerprint != nil }, set: { if !$0 { osint.declinePendingKey() } })
        ) { fingerprintSheet }
        .sheet(isPresented: $enteringServicePassword) { servicePasswordSheet }
        .sheet(isPresented: Binding(get: { keyBeingSet != nil }, set: { if !$0 { keyBeingSet = nil } })) { keySheet }
    }

    private func fill() {
        guard let settings, !loaded || !osint.busy else { return }
        if !loaded {
            host = settings.host
            port = String(settings.port)
            login = settings.login
            loaded = true
        }
    }

    // MARK: Connection

    private func connectionFields(_ settings: OSINTSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Хост", text: $host).textFieldStyle(.roundedBorder).accessibilityIdentifier("persons.osint.host")
                TextField("Порт", text: $port).textFieldStyle(.roundedBorder).frame(width: 72)
                TextField("Логин SSH", text: $login).textFieldStyle(.roundedBorder).frame(width: 140)
                SecureField("Пароль SSH", text: $password).textFieldStyle(.roundedBorder).frame(width: 160)
                Button("Сохранить") {
                    let secret = password.isEmpty ? nil : password
                    _Concurrency.Task {
                        await osint.saveConnection(host: host, port: Int(port) ?? 22, login: login, password: secret)
                        password = ""
                    }
                }.disabled(osint.busy || host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button("Проверить соединение") { _Concurrency.Task { report = await osint.testConnection() } }
                    .disabled(osint.busy || settings.host.isEmpty).accessibilityIdentifier("persons.osint.test")
                Text(OSINTSettingsRules.status(settings, connected: osint.snapshot?.connected ?? false)).font(.callout)
                    .foregroundStyle(.secondary).accessibilityIdentifier("persons.osint.status")
            }
            if let fingerprint = settings.hostKeyFingerprint {
                Text("Доверенный ключ: \(fingerprint)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let report {
                Text(Self.reportText(report)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func reportText(_ report: OSINTConnectionReport) -> String {
        var parts = [report.trusted ? "ключ подтверждён" : "ключ не подтверждён"]
        if let docker = report.dockerPresent { parts.append(docker ? "Docker есть" : "Docker нет") }
        if let sha = report.checkedOutSHA { parts.append("на сервере \(sha.prefix(7))") }
        if let healthy = report.healthy { parts.append(healthy ? "службы отвечают" : "службы не отвечают") }
        return "Проверка: " + parts.joined(separator: ", ") + "."
    }

    private var fingerprintSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Новый ключ сервера").font(.headline)
            Text("Сервер \(settings?.host ?? "") предъявил ключ с отпечатком:")
            Text(osint.pendingFingerprint ?? "").font(.body.monospaced()).textSelection(.enabled)
            Text("Сравните его с отпечатком, который показывает сервер. Доверяйте только совпадающему ключу.").font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена") { osint.declinePendingKey() }.keyboardShortcut(.cancelAction)
                Button("Доверять") { osint.trustPendingKey() }.keyboardShortcut(.defaultAction).accessibilityIdentifier(
                    "persons.osint.trust")
            }
        }.padding(20).frame(width: 520)
    }

    // MARK: Installation

    private func installationRows(_ settings: OSINTSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(OSINTSettingsRules.installButtonTitle(settings, pin: FlowsintPin.current)) {
                    _Concurrency.Task { await osint.install() }
                }
                .disabled(osint.installing || osint.busy || !OSINTSettingsRules.canInstall(settings))
                .accessibilityIdentifier("persons.osint.install")
                if osint.installing { ProgressView().controlSize(.small) }
                if settings.installedSHA != nil {
                    Button("Открыть веб-интерфейс") {
                        _Concurrency.Task { if let url = await osint.webRootURL() { NSWorkspace.shared.open(url) } }
                    }
                    Button("Скопировать пароль веб-интерфейса") {
                        _Concurrency.Task {
                            guard let secret = await osint.servicePassword() else {
                                osint.error = "Пароль служебного пользователя не сохранён в Связке ключей."
                                return
                            }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(secret, forType: .string)
                        }
                    }
                }
            }
            if !settings.envBackupAvailable {
                Text("Файл .env на сервере создан не этим Makosh: его секреты не сохранены в Связке ключей.").font(.caption)
                    .foregroundStyle(.orange)
            }
            if !osint.installLog.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(osint.installLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Служебный пользователь flowsint: \(settings.serviceEmail). Веб-интерфейс открывается через SSH-туннель.").font(.caption)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(OSINTDialogRules.responsibility).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("persons.osint.responsibility")
        }
    }

    // MARK: Service user

    private var serviceUserRows: some View {
        HStack {
            Label("Сервер не принял пароль служебного пользователя.", systemImage: "exclamationmark.triangle").font(.callout)
                .foregroundStyle(.orange)
            Button("Ввести пароль служебного пользователя…") { enteringServicePassword = true }
            Button("Зарегистрировать нового служебного пользователя") { _Concurrency.Task { _ = await osint.registerNewServiceUser() } }
        }
    }

    private var servicePasswordSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Пароль служебного пользователя").font(.headline)
            Text("Учётная запись \(settings?.serviceEmail ?? "") на сервере flowsint. Пароль сохраняется только в Связке ключей.").font(
                .caption
            )
            .foregroundStyle(.secondary)
            SecureField("Пароль", text: $servicePasswordDraft).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Отмена") {
                    servicePasswordDraft = ""
                    enteringServicePassword = false
                }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    let secret = servicePasswordDraft
                    servicePasswordDraft = ""
                    enteringServicePassword = false
                    _Concurrency.Task { _ = await osint.setServicePassword(secret) }
                }.keyboardShortcut(.defaultAction).disabled(servicePasswordDraft.isEmpty)
            }
        }.padding(20).frame(width: 440)
    }

    // MARK: Keys

    private func keysRows(_ settings: OSINTSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Ключи сторонних источников").font(.callout)
                Spacer()
                Button("Обновить") { _Concurrency.Task { await osint.refreshKeys() } }.disabled(osint.busy || settings.installedSHA == nil)
            }
            ForEach(OSINTEnricher.knownKeys, id: \.self) { name in
                let present = osint.snapshot?.serverKeyNames.contains(name) ?? false
                HStack {
                    Text(name).font(.callout.monospaced())
                    Text(OSINTSettingsRules.keyState(name: name, serverKeyNames: osint.snapshot?.serverKeyNames ?? [])).font(.caption)
                        .foregroundStyle(present ? Color.secondary : Color.orange)
                    Spacer()
                    Button("Задать…") { keyBeingSet = name }.disabled(osint.busy || settings.installedSHA == nil)
                    if present { Button("Удалить") { _Concurrency.Task { await osint.removeKey(name: name) } }.disabled(osint.busy) }
                }
            }
            Text("Ключи хранятся в Связке ключей и в зашифрованном хранилище flowsint; в журнал и Git они не попадают.").font(.caption)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keySheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ключ \(keyBeingSet ?? "")").font(.headline)
            SecureField("Значение", text: $keyDraft).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Отмена") {
                    keyDraft = ""
                    keyBeingSet = nil
                }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    let name = keyBeingSet ?? ""
                    let value = keyDraft
                    keyDraft = ""
                    keyBeingSet = nil
                    _Concurrency.Task { await osint.setKey(name: name, value: value) }
                }.keyboardShortcut(.defaultAction).disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(20).frame(width: 440)
    }

    // MARK: Enricher sets

    private func enricherRows(_ settings: OSINTSettings) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Источники").font(.callout)
            HStack(alignment: .top, spacing: 24) {
                enricherColumn("Вручную", selected: settings.manualEnrichers) { set in
                    _Concurrency.Task { await osint.setEnricherSets(manual: set, automatic: settings.automaticEnrichers) }
                }
                enricherColumn("Автоматически", selected: settings.automaticEnrichers) { set in
                    _Concurrency.Task { await osint.setEnricherSets(manual: settings.manualEnrichers, automatic: set) }
                }
            }
            Text(
                "Автоматически обогащаются только люди из книг с флагом «Обогащать автоматически», не более \(settings.automaticRunsPerHour) запусков в час."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func enricherColumn(_ title: String, selected: Set<OSINTEnricher>, save: @escaping (Set<OSINTEnricher>) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(OSINTEnricher.allCases, id: \.self) { enricher in
                Toggle(
                    enricher.title + (enricher.requiredKey.map { " (\($0))" } ?? ""),
                    isOn: Binding(
                        get: { selected.contains(enricher) },
                        set: { on in
                            var set = selected
                            if on { set.insert(enricher) } else { set.remove(enricher) }
                            save(set)
                        })
                ).toggleStyle(.checkbox).font(.callout)
            }
        }
    }

    // MARK: Attempts

    private var attemptsRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Открытые попытки OSINT").font(.callout)
            let attempts = osint.snapshot?.openAttempts ?? []
            if attempts.isEmpty { Text("Все запросы к серверу flowsint подтверждены.").font(.caption).foregroundStyle(.secondary) }
            ForEach(attempts) { attempt in
                HStack {
                    Text(Self.attemptText(attempt)).font(.callout)
                    Spacer()
                    if attempt.state == .unknown {
                        Button("Проверить") { _Concurrency.Task { await osint.settle(attemptID: attempt.id) } }
                        Button("Отказаться") { _Concurrency.Task { await osint.dismiss(attemptID: attempt.id) } }
                    }
                }
            }
        }
    }

    static func attemptText(_ attempt: OSINTAttempt) -> String {
        let kind: String =
            switch attempt.kind {
            case .createSketch: "создание схемы"
            case .addNode: "добавление узла"
            case .launch: "запуск источника \(attempt.payload.enricher?.title ?? "")"
            case .createKey: "запись ключа \(attempt.payload.keyName ?? "")"
            case .deleteKey: "удаление ключа \(attempt.payload.keyName ?? "")"
            case .deleteSketch: "удаление схемы"
            }
        let state: String =
            switch attempt.state {
            case .queued: "в очереди"
            case .sent: "отправлено"
            case .unknown: "исход неизвестен"
            case .confirmed: "подтверждено"
            case .rejected: "отклонено"
            }
        return "\(kind.prefix(1).uppercased())\(kind.dropFirst()) — \(state)"
    }
}
