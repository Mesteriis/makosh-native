import SwiftUI
import MakoshCore
import MakoshTelemost

struct TelemostHistoryRow: Identifiable, Sendable {
    let id: Int64
    let text: String
    nonisolated static func render(_ values: [TelemostRetainedVersion]) -> [Self] {
        values.map { version in
            let decoder = JSONDecoder()
            let text: String
            if version.kind == "local", let value = try? decoder.decode(TelemostLocalMeeting.self, from: version.payload) {
                text = [value.localTitle, value.validatedURL.url.absoluteString, value.notes, value.hidden ? "Скрыта" : "", value.starred ? "Избранное" : "", value.cohostsComplete ? "Соорганизаторы: полный список" : "Соорганизаторы: неполный список", value.cohosts.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: "\n")
            } else if let value = try? decoder.decode(TelemostConference.self, from: version.payload) {
                text = value.joinURL.url.absoluteString + "\nЗал ожидания: " + (value.waitingRoom?.title ?? value.waitingRoomRaw)
            } else { text = "Версия сохранена; формат представления недоступен." }
            return .init(id: version.sequence, text: text)
        }
    }
}
struct TelemostHistoryView: View {
    @ObservedObject var model: TelemostWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [TelemostHistoryRow] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Постоянная история").font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            Text("Полученные версии остаются после недоступности встречи или отключения аккаунта.").foregroundStyle(.secondary)
            List(rows) { row in VStack(alignment: .leading, spacing: 8) { Text("Версия \(row.id)").font(.caption); Text(row.text).textSelection(.enabled) }.padding(.vertical, 8) }
            if model.historyHasMore { Button("Ещё версии") { Task { await model.loadHistory(more: true); await render() } }.disabled(model.busy) }
        }.padding(24).frame(width: 680, height: 560)
        .task { await model.loadHistory(); await render() }
    }
    private func render() async {
        let context = model.contextID, values = model.history
        do {
            let result = try await BackgroundWork.run { TelemostHistoryRow.render(values) }
            guard context == model.contextID else { return }; rows = result
        } catch { if context == model.contextID { model.error = "Не удалось подготовить представление истории." } }
    }
}
@MainActor enum TelemostExportPanel {
    static func choose(synthetic: Bool) async -> URL? {
        let args = CommandLine.arguments
        let root = args.firstIndex(of: "--telemost-qa-exports").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        if synthetic, root == nil { return nil }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "telemost-history.jsonl"; panel.directoryURL = root
        return await withCheckedContinuation { continuation in panel.begin { result in continuation.resume(returning: result == .OK ? panel.url : nil) } }
    }
}
