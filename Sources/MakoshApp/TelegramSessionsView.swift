import SwiftUI
import MakoshTelegram

private struct TelegramSessionConfirmation: Identifiable {
    let id = UUID()
    let change: TelegramSessionChange
    let context: UUID
    var title: String {
        switch change {
        case .terminate: "Завершить сеанс?"
        case .terminateOthers: "Завершить все другие сеансы?"
        case .ttl: "Изменить срок неактивности?"
        case .secretChats: "Изменить приём секретных чатов?"
        case .calls: "Изменить приём звонков?"
        }
    }
    var details: String {
        switch change {
        case let .terminate(session): "\(session.device) · \(session.app). На этом устройстве потребуется повторный вход."
        case .terminateOthers: "Все устройства, кроме текущего, будут отключены от Telegram."
        case let .ttl(days): "Telegram будет завершать сеансы, неактивные \(days) дней. Сохранённая переписка Макоша останется."
        case let .secretChats(session, value): "\(session.device): \(value ? "разрешить" : "запретить") новые секретные чаты."
        case let .calls(session, value): "\(session.device): \(value ? "разрешить" : "запретить") входящие звонки."
        }
    }
    var destructive: Bool { switch change { case .terminate, .terminateOthers: true; default: false } }
}

struct TelegramSessionsView: View {
    @ObservedObject var controller: TelegramSessionsController
    let synthetic: Bool
    var webSessions: TelegramWebSessionsController? = nil
    @State private var showWebSessions = false
    @State private var selected: TelegramAccountSession?
    @State private var selectedTTL: Int32?
    @State private var confirmation: TelegramSessionConfirmation?
    @State private var validationFailed = false
    private var enabled: Bool { controller.status == .ready && controller.mutationStatus != .saving && controller.mutationStatus != .uncertain }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if controller.status == .loading || controller.mutationStatus == .saving { ProgressView().controlSize(.small) }
                Text(validationFailed ? "Список изменился. Обновите устройства и подтвердите заново." : telegramSessionsStatus(controller)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("telegram.sessions.status")
                Spacer()
                Button("Обновить") { controller.refresh() }.disabled(controller.mutationStatus == .saving).accessibilityIdentifier("telegram.sessions.refresh")
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if let snapshot = controller.snapshot {
                Form {
                    Section {
                        if webSessions != nil { Button("Подключённые сайты") { showWebSessions = true }.accessibilityIdentifier("telegram.sessions.websites") }
                    }
                    Section("Это устройство") {
                        if let current = snapshot.current { row(current) }
                        Button("Завершить все другие сеансы", role: .destructive) { confirm(.terminateOthers) }
                            .buttonStyle(.plain).foregroundStyle(.red)
                            .disabled(!enabled || snapshot.sessions.count < 2).accessibilityIdentifier("telegram.sessions.terminateOthers")
                    }
                    if !snapshot.pending.isEmpty {
                        Section("Незавершённые входы") {
                            ForEach(snapshot.pending) { row($0) }
                            Text("На этих устройствах ещё не завершён вход с паролем.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !snapshot.others.isEmpty { Section("Активные сеансы") { ForEach(snapshot.others) { row($0) } } }
                    Section("Автоматически завершать старые сеансы") {
                        Picker("Если неактивны", selection: Binding(get: { selectedTTL ?? snapshot.ttlDays }, set: { selectedTTL = $0 })) {
                            Text("1 неделя").tag(Int32(7)); Text("1 месяц").tag(Int32(31))
                            Text("3 месяца").tag(Int32(93)); Text("6 месяцев").tag(Int32(186))
                            if ![7, 31, 93, 186].contains(snapshot.ttlDays) { Text("\(snapshot.ttlDays) дней").tag(snapshot.ttlDays) }
                        }.disabled(!enabled).accessibilityIdentifier("telegram.sessions.ttl")
                        if let selectedTTL, selectedTTL != snapshot.ttlDays {
                            Button("Изменить срок") { confirm(.ttl(selectedTTL)) }.disabled(!enabled)
                                .accessibilityIdentifier("telegram.sessions.ttl.apply")
                        }
                    }
                }.formStyle(.grouped)
            } else if controller.status == .loading { Spacer(); ProgressView("Загружаем устройства…"); Spacer() }
            else { ContentUnavailableView("Список устройств недоступен", systemImage: "desktopcomputer", description: Text("Подключите выбранный аккаунт Telegram или повторите загрузку.")) }
        }
        .sheet(isPresented: $showWebSessions) { if let webSessions { TelegramWebSessionsView(controller: webSessions) } }
        .onAppear { controller.open() }.onDisappear { controller.close() }
        .onChange(of: controller.snapshot?.accountID) { _, _ in selected = nil; confirmation = nil }
        .sheet(item: $selected) { session in
            TelegramSessionDetailView(controller: controller, sessionID: session.id, synthetic: synthetic) { selected = nil }
        }
        .alert(confirmation?.title ?? "Устройства", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { request in
            Button("Отмена", role: .cancel) { confirmation = nil; selectedTTL = nil }
            Button("Подтвердить", role: request.destructive ? .destructive : nil) { validationFailed = !controller.apply(request.change, contextID: request.context); confirmation = nil; selectedTTL = nil }
        } message: { request in Text((synthetic ? "Симуляция. " : "") + request.details) }
    }
    private func confirm(_ change: TelegramSessionChange) { validationFailed = false; confirmation = .init(change: change, context: controller.contextID) }
    private func row(_ session: TelegramAccountSession) -> some View {
        Button { selected = session } label: {
            HStack(spacing: 14) {
                Image(systemName: session.platform.localizedCaseInsensitiveContains("android") || session.platform.localizedCaseInsensitiveContains("ios") ? "iphone" : "desktopcomputer")
                    .font(.title2).foregroundStyle(Color.accentColor).frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.device).font(.headline)
                    Text("\(session.app) \(session.appVersion)").font(.callout)
                    Text([session.country, session.region].filter { !$0.isEmpty }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !session.isCurrent { Text(Date(timeIntervalSince1970: Double(session.active)), style: .relative).font(.caption).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("telegram.sessions.device.\(session.id)")
    }

}

private struct TelegramSessionDetailView: View {
    @ObservedObject var controller: TelegramSessionsController
    let sessionID: Int64
    let synthetic: Bool
    let close: () -> Void
    @State private var confirmation: TelegramSessionConfirmation?
    @State private var validationFailed = false
    private var enabled: Bool { controller.status == .ready && controller.mutationStatus != .saving && controller.mutationStatus != .uncertain }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Устройство").font(.headline); Spacer(); Button("Готово", action: close) }.padding()
            Divider()
            if validationFailed || controller.mutationStatus != .idle {
                Text(validationFailed ? "Список изменился. Откройте устройство заново." : telegramSessionsStatus(controller))
                    .font(.caption).foregroundStyle(.secondary).padding(10).accessibilityIdentifier("telegram.sessions.detailStatus")
            }
            if let session = controller.snapshot?.sessions.first(where: { $0.id == sessionID }) {
                Form {
                    Section {
                        LabeledContent("Устройство", value: session.device)
                        LabeledContent("Система", value: "\(session.platform) \(session.systemVersion)")
                        LabeledContent("Приложение", value: "\(session.app) \(session.appVersion)")
                        if !session.ip.isEmpty { LabeledContent("IP", value: session.ip) }
                        LabeledContent("Местоположение", value: [session.country, session.region].filter { !$0.isEmpty }.joined(separator: ", "))
                        LabeledContent("Вход") { Text(Date(timeIntervalSince1970: Double(session.created)), style: .date) }
                    }.textSelection(.enabled)
                    if !session.pending {
                        Section("Принимать на этом устройстве") {
                            Toggle("Секретные чаты", isOn: Binding(get: { session.acceptsSecretChats }, set: { confirm(.secretChats(session, $0)) })).accessibilityIdentifier("telegram.sessions.secretChats")
                            Toggle("Входящие звонки", isOn: Binding(get: { session.acceptsCalls }, set: { confirm(.calls(session, $0)) })).accessibilityIdentifier("telegram.sessions.calls")
                        }.disabled(!enabled)
                    }
                    if !session.isCurrent {
                        Section { Button("Завершить сеанс", role: .destructive) { confirm(.terminate(session)) }.buttonStyle(.plain).foregroundStyle(.red).disabled(!enabled).accessibilityIdentifier("telegram.sessions.terminate") }
                    }
                }.formStyle(.grouped)
            } else { ContentUnavailableView("Сеанс больше не доступен", systemImage: "desktopcomputer") }
        }.frame(width: 470, height: 560)
        .alert(confirmation?.title ?? "Устройство", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { request in
            Button("Отмена", role: .cancel) { confirmation = nil }
            Button("Подтвердить", role: request.destructive ? .destructive : nil) { validationFailed = !controller.apply(request.change, contextID: request.context); confirmation = nil }
        } message: { request in Text((synthetic ? "Симуляция. " : "") + request.details) }
    }
    private func confirm(_ change: TelegramSessionChange) { validationFailed = false; confirmation = .init(change: change, context: controller.contextID) }
}

@MainActor private func telegramSessionsStatus(_ controller: TelegramSessionsController) -> String {
    if controller.status == .failed || controller.status == .timedOut {
        if controller.mutationStatus == .saved { return "Изменение подтверждено; список не удалось обновить. Повторите обновление." }
        if controller.mutationStatus != .uncertain { return "Не удалось загрузить устройства. Повторите обновление." }
    }
    switch controller.mutationStatus {
    case .saving: return "Сохраняем…"
    case .saved: return "Изменение подтверждено"
    case .changed: return "Список изменился. Проверьте устройства и подтвердите заново."
    case .failed: return "Telegram отклонил изменение."
    case .freshReset: return "Telegram запрещает завершать сеансы сразу после нового входа. Повторите позже."
    case .uncertain: return "Результат неизвестен. Обновите список перед новым действием."
    case .idle: return "Текущий сеанс останется подключённым"
    }
}
