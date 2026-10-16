import SwiftUI
import MakoshTeams

struct TeamsOutboxView: View {
    @ObservedObject var model: TeamsComposerModel
    @Environment(\.dismiss) private var dismiss
    @State private var resolving: TeamsOutgoing?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Исходящие Teams").font(.title2.bold()); Spacer(); Button("Обновить") { Task { await model.loadOutbox(reset: true) } }; Button("Закрыть") { dismiss() } }
            Text((model.isSynthetic ? "Синтетическая проверка: в Microsoft ничего не отправлялось. " : "") + "Принято сервисом — это подтверждение Graph. Неизвестный результат после сбоя требует ручной проверки; автоматического повтора нет.").font(.caption).foregroundStyle(.secondary)
            List(model.outbox) { outgoing in
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(teamsOutgoingTitle(outgoing, synthetic: model.isSynthetic)).font(.headline); Spacer(); Text(outgoing.createdAt, format: .dateTime.day().month().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                    Text(outgoing.content.text.isEmpty ? "Сообщение с файлами" : outgoing.content.text).lineLimit(4).textSelection(.enabled)
                    if !outgoing.content.fileIDs.isEmpty { Text("Файлов: \(outgoing.content.fileIDs.count)").font(.caption) }
                    if let stages = outgoing.fileSubmission?.stages, !stages.isEmpty { Text("Сохранённых этапов: \(stages.count)").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        if outgoing.state == .unknown { Button("Уточнить результат…") { resolving = outgoing } }
                        if outgoing.state == .prepared { Button("Отправить подготовленное") { Task { await model.resume(outgoing) } } }
                        if outgoing.state == .notSent, outgoing.fileSubmission == nil { Button("Создать отдельную копию") { Task { await model.copy(outgoing) } } }
                        if outgoing.state == .notSent, outgoing.fileSubmission != nil { Text("Для новой отправки файлов подготовьте новый план доступа.").font(.caption) }
                    }
                }.padding(.vertical, 8)
            }.accessibilityIdentifier("teams.outbox.list")
            if model.outbox.isEmpty { Text("Исходящих пока нет").foregroundStyle(.secondary) }
            if model.outboxHasMore { Button("Загрузить ещё") { Task { await model.loadOutbox(reset: false) } }.disabled(model.outboxBusy) }
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
        }.padding(20).frame(width: 680, height: 570).task { await model.loadOutbox(reset: true) }
        .confirmationDialog("Уточните результат после проверки в Teams", isPresented: Binding(get: { resolving != nil }, set: { if !$0 { resolving = nil } }), titleVisibility: .visible) {
            if let outgoing = resolving {
                Button("Сообщение было отправлено") { Task { await model.resolve(outgoing, sent: true) }; resolving = nil }
                Button("Подтверждаю: сообщение не отправлено") { Task { await model.resolve(outgoing, sent: false) }; resolving = nil }
            }
            Button("Отмена", role: .cancel) { resolving = nil }
        } message: { Text("Выбор сохраняет результат этой попытки. Он не запускает повторную отправку и не удаляет загруженные файлы или выданные права.") }
    }
}
func teamsOutgoingTitle(_ outgoing: TeamsOutgoing, synthetic: Bool) -> String {
    if outgoing.receipt?.userResolved == true { return outgoing.state == .accepted ? "Отмечено вами как отправленное" : "Отмечено вами как неотправленное" }
    if synthetic, outgoing.state == .accepted { return "QA · синтетическое подтверждение" }
    return switch outgoing.state { case .prepared: "Подготовлено"; case .dispatching: "Попытка выполняется"; case .accepted: "Принято сервисом"; case .notSent: "Не отправлено"; case .unknown: "Результат неизвестен" }
}
