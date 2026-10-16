import SwiftUI
import MakoshCore
import MakoshTeams

struct TeamsArchiveRow: Identifiable, Sendable { let id: UUID; let sequence: Int64; let text: String; let date: Date; let source: MessageArchiveSource }
@MainActor final class TeamsHistoryModel: ObservableObject {
    @Published private(set) var rows: [TeamsArchiveRow] = []
    @Published private(set) var busy = false
    @Published private(set) var hasMore = false
    @Published var error: String?
    private let worker: any TeamsServing
    private let scope: TeamsScope
    private var before: Int64?
    private var generation = UUID()
    init(worker: any TeamsServing, scope: TeamsScope) { self.worker = worker; self.scope = scope }
    func cancel() { generation = UUID() }
    func load() async {
        guard !busy else { return }; busy = true; let token = generation
        defer { if generation == token { busy = false } }
        do {
            let records = try await worker.archivePage(scope: scope, before: before)
            let projected = try await BackgroundWork.run { records.map { record in
                let text: String
                switch record.observation.event {
                case let .message(content):
                    let type = record.observation.sourcePayload.flatMap { try? JSONDecoder().decode(TeamsMessage.self, from: $0).contentType } ?? "text"
                    text = TeamsTextProjection.plain(content.text, contentType: type)
                case .deleted: text = "Удаление на сервере · предыдущие версии сохранены"
                case .removedFromSource: text = "Сообщение исчезло из источника · архив сохранён"
                }
                return TeamsArchiveRow(id: record.id, sequence: record.sequence, text: text, date: record.observation.observedAt, source: record.observation.source)
            } }
            guard generation == token, !Task.isCancelled else { return }
            rows += projected; before = records.last?.sequence; hasMore = records.count == 50
        } catch { if generation == token { self.error = teamsFailureMessage(error) } }
    }
    func export() async {
        let token = generation
        do {
            let lease = try await worker.exportArchive(scope: scope)
            guard generation == token, !Task.isCancelled else { await lease.release(); return }
            do { try await TeamsFilePanels.save(lease, name: "Teams-archive.jsonl"); await lease.release() }
            catch { await lease.release(); throw error }
        } catch { if generation == token { self.error = teamsFailureMessage(error) } }
    }
}
struct TeamsHistoryView: View {
    let title: String
    @StateObject private var model: TeamsHistoryModel
    @Environment(\.dismiss) private var dismiss
    init(worker: any TeamsServing, scope: TeamsScope, title: String) { self.title = title; _model = StateObject(wrappedValue: TeamsHistoryModel(worker: worker, scope: scope)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("История · " + title).font(.title2.bold()); Spacer(); Button("Экспорт JSONL…") { Task { await model.export() } }.disabled(model.busy).accessibilityIdentifier("teams.archive.export"); Button("Закрыть") { dismiss() } }
            Text("Все полученные версии хранятся бессрочно, включая изменения и удаления на сервере.").font(.caption).foregroundStyle(.secondary)
            List(model.rows) { row in VStack(alignment: .leading, spacing: 6) { Text(row.text).textSelection(.enabled); Text(row.date, format: .dateTime.day().month().year().hour().minute().second()).font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 6) }.accessibilityIdentifier("teams.archive.list")
            if model.hasMore { Button("Ещё версии") { Task { await model.load() } }.disabled(model.busy) }
            if model.busy { ProgressView() }
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
        }.padding(20).frame(width: 720, height: 600).task { await model.load() }.onDisappear { model.cancel() }
    }
}
