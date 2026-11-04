import SwiftUI
import MakoshCore
import MakoshTeams

struct TeamsHistoryView: View {
    let title: String
    @StateObject private var model: TeamsHistoryModel
    @Environment(\.dismiss) private var dismiss
    init(worker: any TeamsServing, scope: TeamsScope, title: String) {
        self.title = title
        _model = StateObject(wrappedValue: TeamsHistoryModel(worker: worker, scope: scope, saveArchive: TeamsFilePanels.save))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("История · " + title).font(.title2.bold())
                Spacer()
                Button("Экспорт JSONL…") { Task { await model.export() } }.disabled(model.busy).accessibilityIdentifier(
                    "teams.archive.export")
                Button("Закрыть") { dismiss() }
            }
            Text("Все полученные версии хранятся бессрочно, включая изменения и удаления на сервере.").font(.caption).foregroundStyle(
                .secondary)
            List(model.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.text).textSelection(.enabled)
                    Text(row.date, format: .dateTime.day().month().year().hour().minute().second()).font(.caption).foregroundStyle(
                        .secondary)
                }.padding(.vertical, 6)
            }.accessibilityIdentifier("teams.archive.list")
            if model.hasMore { Button("Ещё версии") { Task { await model.load() } }.disabled(model.busy) }
            if model.busy { ProgressView() }
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
        }.padding(20).frame(width: 720, height: 600).task { await model.load() }.onDisappear { model.cancel() }
    }
}
