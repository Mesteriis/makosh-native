import SwiftUI
import MakoshTelegram

struct TelegramWebSessionsView: View {
    @ObservedObject var controller: TelegramWebSessionsController
    @Environment(\.dismiss) private var dismiss
    private struct Confirmation: Identifiable {
        let id = UUID(), change: TelegramWebSessionChange, context: UUID
        var details: String {
            switch change {
            case let .terminate(session): "Завершить вход на \(session.domain) через бота \(session.botID)?"
            case .terminateAll: "Завершить вход на всех подключённых сайтах?"
            }
        }
    }
    @State private var confirmation: Confirmation?
    @State private var validationFailed = false
    private var enabled: Bool { controller.status == .ready && controller.mutationStatus != .saving && controller.mutationStatus != .uncertain }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Подключённые сайты").font(.headline); Spacer(); Button("Готово") { dismiss() } }.padding()
            HStack {
                if controller.status == .loading || controller.mutationStatus == .saving { ProgressView().controlSize(.small) }
                Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("telegram.webSessions.status")
                Spacer()
                Button("Обновить") { validationFailed = false; controller.refresh() }.disabled(controller.mutationStatus == .saving)
                    .accessibilityIdentifier("telegram.webSessions.refresh")
            }.padding(.horizontal).padding(.bottom, 8)
            if let snapshot = controller.snapshot {
                Form {
                    Section {
                        Button("Завершить все веб-сеансы…", role: .destructive) { confirm(.terminateAll) }
                            .disabled(!enabled || snapshot.sessions.isEmpty).accessibilityIdentifier("telegram.webSessions.terminateAll")
                        Text("Сайты, на которые выполнен вход через Telegram. Завершение входа не блокирует бота и сохраняет архив Макоша.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if snapshot.sessions.isEmpty { Section { Text("Нет подключённых сайтов").accessibilityIdentifier("telegram.webSessions.empty") } }
                    ForEach(snapshot.ordered) { session in
                        Section(session.domain) {
                            LabeledContent("Бот", value: String(session.botID))
                            LabeledContent("Браузер", value: session.browser)
                            LabeledContent("Система", value: session.platform)
                            LabeledContent("IP", value: session.ip)
                            LabeledContent("Регион", value: session.region)
                            LabeledContent("Вход") { Text(Date(timeIntervalSince1970: Double(session.created)), format: .dateTime) }
                            LabeledContent("Последняя активность") { Text(Date(timeIntervalSince1970: Double(session.active)), format: .dateTime) }
                            Button("Завершить вход…", role: .destructive) { confirm(.terminate(session)) }
                                .disabled(!enabled).accessibilityIdentifier("telegram.webSessions.terminate.\(session.id)")
                        }
                    }
                }.formStyle(.grouped)
            } else if controller.status == .loading { Spacer(); ProgressView("Загрузка сайтов…"); Spacer() }
            else { ContentUnavailableView("Список сайтов недоступен", systemImage: "globe", description: Text("Повторите загрузку для выбранного аккаунта.")) }
        }.frame(width: 520, height: 590)
            .onAppear { controller.open() }.onDisappear { controller.close() }
            .onChange(of: controller.contextID) { _, _ in confirmation = nil }
            .alert("Завершить веб-сеанс?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { request in
                Button("Отмена", role: .cancel) { confirmation = nil }
                Button("Завершить", role: .destructive) { validationFailed = !controller.apply(request.change, contextID: request.context); confirmation = nil }
            } message: { Text($0.details) }
    }
    private func confirm(_ change: TelegramWebSessionChange) { confirmation = .init(change: change, context: controller.contextID) }
    private var status: String {
        if validationFailed { return "Список изменился. Обновите его и подтвердите заново." }
        switch controller.mutationStatus {
        case .saving: return "Завершаем вход…"
        case .uncertain: return "Результат неизвестен. Обновите список перед повторным действием."
        case .changed: return "Список изменился. Проверьте актуальные сайты."
        case .failed, .freshReset: return "Telegram не подтвердил завершение входа."
        case .saved:
            if controller.status == .failed || controller.status == .timedOut { return "Вход завершён. Не удалось обновить список; нажмите «Обновить»." }
            return controller.status == .ready ? "Список обновлён после завершения входа." : "Вход завершён. Проверяем список…"
        case .idle: break
        }
        switch controller.status {
        case .failed, .timedOut: return "Не удалось загрузить сайты. Повторите загрузку."
        case .loading: return "Загрузка…"
        default: return "Подключённые сайты выбранного аккаунта"
        }
    }
}
