import SwiftUI
import MakoshTelemost

struct TelemostOperationsView: View {
    @ObservedObject var model: TelemostWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?
    @State private var link = ""
    @State private var confirm = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(model.isSynthetic ? "Синтетический журнал · QA" : "Журнал операций").font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            List(model.operations, selection: $selected) { operation in
                VStack(alignment: .leading, spacing: 6) {
                    Text(operation.createdAt.formatted()); Text(title(operation.state)).font(.headline)
                    if let status = operation.rejectionStatus { Text("Ответ API: \(status)") }
                    if case .update(_, let patch) = operation.payload { Text("Запрошено: " + patch.waitingRoom.title) }
                    if let receipt = operation.receipt {
                        Text(operation.state == .resolved ? "Наблюдение GET; не доказательство прежнего запроса" : "Ответ API")
                        Text(receipt.joinURL.url.absoluteString).textSelection(.enabled)
                        Text("Зал ожидания: " + (receipt.waitingRoom?.title ?? receipt.waitingRoomRaw))
                    }
                    Text(operation.attemptID.uuidString).font(.caption).foregroundStyle(.secondary)
                }.tag(operation.id)
            }.frame(minHeight: 200)
            if let selected, let operation = model.operations.first(where: { $0.id == selected }), operation.state == .unknown {
                Text(operation.payload.scope == nil ? "Запрос мог выполниться. Можно связать наблюдение GET или явно разрешить новую попытку с риском дубликата." : "Изменение могло выполниться. Требуется GET точной встречи и просмотр наблюдения; разрешить повтор без чтения нельзя.").foregroundStyle(.orange)
                TextField("Известная ссылка для проверки GET", text: $link).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Проверить и связать наблюдение") { if let url = try? TelemostMeetingURL(link) { Task { await model.resolve(selected, resolution: .attachVerifiedMeetingURL(url)) } } }.disabled(model.busy || (try? TelemostMeetingURL(link)) == nil || !model.can(.read))
                    if operation.payload.scope == nil { Button("Разрешить новую попытку…") { confirm = true }.disabled(model.busy) }
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
        }.padding(24).frame(width: 650, height: 520)
        .confirmationDialog("Прежний запрос мог выполниться. Новая попытка может создать дубликат.", isPresented: $confirm, titleVisibility: .visible) {
            Button("Принимаю риск; разрешить новую попытку") { if let selected { Task { await model.resolve(selected, resolution: .dismissUnknownAndAllowNewAttempt) } } }
        }
    }
    private func title(_ state: TelemostOperationState) -> String {
        switch state { case .prepared: "Подготовлено"; case .dispatching: "Ожидается ответ API"; case .accepted: "API подтвердил результат"; case .rejected: "API отклонил"; case .unknown: "Результат неизвестен · повтор заблокирован"; case .resolved: "Неопределённость разрешена пользователем" }
    }
}
