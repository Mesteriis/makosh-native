import XCTest
@testable import MakoshTelegram

private nonisolated func cacheSnapshot(account: Int64 = 11, bytes: Int64 = 8) -> TelegramCacheSnapshot {
    .init(accountID: account, items: [.init(namespace: 0, id: 1, bytes: bytes, kind: .files, resources: ["telegram-cloud-document-2-101"])])
}
@MainActor final class TelegramCacheControllerTests: XCTestCase {
    @MainActor private final class Safety { var allowed = true }
    private final class Request: TelegramCacheRequest { func cancel() {} }
    private final class Provider: TelegramCacheProvider {
        var accountID: Int64
        var snapshot: TelegramCacheSnapshot
        var writes = 0, hold = false, unknown = false
        var completion: (@MainActor (TelegramCacheEvent) -> Void)?
        init(account: Int64 = 11) { accountID = account; snapshot = cacheSnapshot(account: account) }
        func scan(receive: @escaping @MainActor (TelegramCacheSnapshot?) -> Void) -> any TelegramCacheRequest {
            receive(snapshot); return Request()
        }
        func clear(expected: TelegramCacheSnapshot, categories: Set<TelegramCacheKind>, permitted: @escaping @MainActor () -> Bool,
            receive: @escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest {
            guard expected == snapshot else { receive(.changed(snapshot)); return Request() }
            guard permitted() else { receive(.refused); return Request() }
            writes += 1; completion = receive; receive(.committing)
            if unknown { receive(.uncertain) }
            else if !hold {
                snapshot = .init(accountID: accountID, items: snapshot.items.filter { !categories.contains($0.kind) })
                receive(.finished(snapshot))
            }
            return Request()
        }
    }
    func testOpeningOnlyReadsAndExplicitSameContextConfirmationClearsSelectedCache() throws {
        let provider = Provider(), c = TelegramCacheController(); c.permitsClear = { true }; c.bind(provider); c.open()
        XCTAssertEqual(c.snapshot, cacheSnapshot()); XCTAssertEqual(provider.writes, 0)
        let confirmation = try XCTUnwrap(c.prepareClear(categories: [.files], contextID: c.contextID))
        XCTAssertEqual(confirmation.byteCount, 8); XCTAssertEqual(provider.writes, 0)
        XCTAssertTrue(c.confirmClear(confirmation)); XCTAssertEqual(c.phase, .idle)
        XCTAssertEqual(c.snapshot?.totalBytes, 0); XCTAssertEqual(provider.writes, 1)
        XCTAssertFalse(c.confirmClear(confirmation)); XCTAssertEqual(provider.writes, 1)
    }
    func testChangedCacheOrLiveSafetyBlockCannotDeleteUnconfirmedResources() throws {
        let provider = Provider(), c = TelegramCacheController(), safety = Safety()
        c.permitsClear = { safety.allowed }; c.bind(provider); c.open()
        let first = try XCTUnwrap(c.prepareClear(categories: [.files], contextID: c.contextID))
        provider.snapshot = cacheSnapshot(bytes: 16)
        XCTAssertTrue(c.confirmClear(first)); XCTAssertEqual(provider.writes, 0)
        XCTAssertEqual(c.snapshot?.totalBytes, 16); XCTAssertNotNil(c.error)
        let second = try XCTUnwrap(c.prepareClear(categories: [.files], contextID: c.contextID))
        safety.allowed = false
        XCTAssertFalse(c.confirmClear(second)); XCTAssertEqual(provider.writes, 0)
    }
    func testLateCompletionAfterAccountRebindCannotReplaceCurrentSnapshot() throws {
        let provider = Provider(), c = TelegramCacheController(); c.permitsClear = { true }; c.bind(provider); c.open()
        provider.hold = true
        let first = try XCTUnwrap(c.prepareClear(categories: [.files], contextID: c.contextID))
        XCTAssertTrue(c.confirmClear(first)); XCTAssertEqual(c.phase, .clearing)
        let old = provider.completion
        let second = Provider(account: 22); c.bind(second); c.open()
        old?(.finished(.init(accountID: 11, items: [])))
        XCTAssertEqual(c.snapshot?.accountID, 22); XCTAssertEqual(c.snapshot?.totalBytes, 8)
        XCTAssertEqual(c.phase, .idle); XCTAssertFalse(c.confirmClear(first))
    }
    func testUnknownClearOutcomeRequiresFreshReadBeforeAnotherConfirmation() throws {
        let provider = Provider(), c = TelegramCacheController(); c.permitsClear = { true }; c.bind(provider); c.open()
        provider.unknown = true
        let first = try XCTUnwrap(c.prepareClear(categories: [.files], contextID: c.contextID))
        XCTAssertTrue(c.confirmClear(first)); XCTAssertEqual(c.phase, .uncertain)
        XCTAssertNil(c.prepareClear(categories: [.files], contextID: c.contextID))
        provider.snapshot = .init(accountID: 11, items: [])
        c.refresh(); XCTAssertEqual(c.phase, .idle); XCTAssertEqual(c.snapshot?.totalBytes, 0); XCTAssertNil(c.error)
    }
    func testNegativeDuplicateOrOverflowingCacheSnapshotCannotAuthorizeClear() {
        let provider = Provider(), c = TelegramCacheController(); c.permitsClear = { true }; c.bind(provider)
        for items in [[TelegramCacheItem(namespace: 0, id: 1, bytes: -1, kind: .files, resources: ["cloud"])],
            [TelegramCacheItem(namespace: 0, id: 1, bytes: Int64.max, kind: .files, resources: ["cloud-a"]),
             TelegramCacheItem(namespace: 0, id: 2, bytes: Int64.max, kind: .files, resources: ["cloud-b"])],
            [TelegramCacheItem(namespace: 0, id: 1, bytes: 1, kind: .files, resources: ["cloud"]),
             TelegramCacheItem(namespace: 0, id: 1, bytes: 1, kind: .files, resources: ["cloud"])]] {
            provider.snapshot = .init(accountID: 11, items: items); c.open()
            XCTAssertNil(c.snapshot); XCTAssertNotNil(c.error)
            XCTAssertNil(c.prepareClear(categories: [.files], contextID: c.contextID))
        }
        XCTAssertEqual(provider.writes, 0)
    }
}
