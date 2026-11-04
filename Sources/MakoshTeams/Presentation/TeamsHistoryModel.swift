import Combine
import Foundation
import MakoshCore

package struct TeamsArchiveRow: Identifiable, Sendable {
    package let id: UUID
    package let sequence: Int64
    package let text: String
    package let date: Date
    package let source: MessageArchiveSource
}
@MainActor package final class TeamsHistoryModel: ObservableObject {
    @Published package private(set) var rows: [TeamsArchiveRow] = []
    @Published package private(set) var busy = false
    @Published package private(set) var hasMore = false
    @Published package var error: String?
    private let worker: any TeamsServing
    private let scope: TeamsScope
    private let saveArchive: @MainActor (TeamsFileLease, String) async throws -> Void
    private var before: Int64?
    private var generation = UUID()
    /// `saveArchive` presents the destination; the app passes its save panel.
    package init(
        worker: any TeamsServing, scope: TeamsScope,
        saveArchive: @escaping @MainActor (TeamsFileLease, String) async throws -> Void
    ) {
        self.worker = worker
        self.scope = scope
        self.saveArchive = saveArchive
    }
    package func cancel() { generation = UUID() }
    package func load() async {
        guard !busy else { return }
        busy = true
        let token = generation
        defer { if generation == token { busy = false } }
        do {
            let records = try await worker.archivePage(scope: scope, before: before)
            let projected = try await BackgroundWork.run {
                records.map { record in
                    let text: String
                    switch record.observation.event {
                    case let .message(content):
                        let type =
                            record.observation.sourcePayload.flatMap { try? JSONDecoder().decode(TeamsMessage.self, from: $0).contentType }
                            ?? "text"
                        text = TeamsTextProjection.plain(content.text, contentType: type)
                    case .deleted: text = "Удаление на сервере · предыдущие версии сохранены"
                    case .removedFromSource: text = "Сообщение исчезло из источника · архив сохранён"
                    }
                    return TeamsArchiveRow(
                        id: record.id, sequence: record.sequence, text: text, date: record.observation.observedAt,
                        source: record.observation.source)
                }
            }
            guard generation == token, !Task.isCancelled else { return }
            rows += projected
            before = records.last?.sequence
            hasMore = records.count == 50
        } catch { if generation == token { self.error = teamsFailureMessage(error) } }
    }
    package func export() async {
        let token = generation
        do {
            let lease = try await worker.exportArchive(scope: scope)
            guard generation == token, !Task.isCancelled else {
                await lease.release()
                return
            }
            do {
                try await saveArchive(lease, "Teams-archive.jsonl")
                await lease.release()
            } catch {
                await lease.release()
                throw error
            }
        } catch { if generation == token { self.error = teamsFailureMessage(error) } }
    }
}
