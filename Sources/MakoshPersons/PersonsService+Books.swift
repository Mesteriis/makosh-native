import Foundation
import MakoshCore

extension PersonsService {
    /// Reads one book; filled in by Task 9. For now it only refreshes the adoption cache.
    @discardableResult
    public func readBook(id: UUID) async throws -> CollectResult {
        guard let book = try await store.book(id: id) else { throw PersonsFailure.notFound }
        let adapter = try await adapter(for: book)
        let changes = try await adapter.changes(cursor: nil)
        lastRemote[id] = changes.cards
        return CollectResult()
    }
}
