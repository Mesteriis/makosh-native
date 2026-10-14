import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramCacheMaintenanceTests: XCTestCase {
    private func item(_ id: Int64, bytes: Int64 = 10, time: Int64? = 1) -> TelegramCacheItem {
        .init(namespace: 0, id: id, bytes: bytes, kind: .files, resources: ["cloud-\(id)"], peerIDs: [11], modifiedAt: time)
    }
    func testAgeSelectsOnlyKnownExpiredResources() {
        let snapshot = TelegramCacheSnapshot(accountID: 11, items: [item(1,time:13_599),item(2,time:13_600),item(3,time:nil),item(4,time:100_001)])
        XCTAssertEqual(TelegramCacheRetention(days:1).selection(from:snapshot,now:100_000).map(\.id),[1])
        XCTAssertEqual(TelegramCacheRetention().selection(from:snapshot,now:100_000),[])
    }
    func testSizeEvictsOldestAfterAge() {
        let snapshot = TelegramCacheSnapshot(accountID:11,items:[item(3,bytes:3_000_000_000,time:30),item(2,bytes:3_000_000_000,time:20),item(1,bytes:3_000_000_000,time:20)])
        XCTAssertEqual(TelegramCacheRetention(limitGB:5).selection(from:snapshot,now:100).map(\.id),[1,2])
    }
    func testFutureUnknownAndActiveRemain() {
        let snapshot = TelegramCacheSnapshot(accountID:11,items:[item(1,time:1),item(2,time:nil),item(3,time:100_001)])
        XCTAssertEqual(TelegramCacheRetention(days:1).selection(from:snapshot,now:100_000,protectedResources:["cloud-1"]),[])
        XCTAssertEqual(TelegramCacheRetention(days:1).selection(from:snapshot,now:-1),[])
    }
    func testPreferencesRoundTripAndRejectMalformed() throws {
        let value = TelegramCacheRetention(days:7,limitGB:16)
        XCTAssertEqual(try TelegramCacheRetention.decode(value.encoded()),value)
        XCTAssertThrowsError(try TelegramCacheRetention(days:-1).encoded())
        XCTAssertThrowsError(try TelegramCacheRetention(limitGB:1).encoded())
        XCTAssertThrowsError(try TelegramCacheRetention.decode("{\"days\":7,\"limitGB\":16,\"version\":2}"))
    }
    private final class Request: TelegramCacheRequest { func cancel() {} }
    private final class Provider: TelegramCacheProvider {
        var accountID: Int64 = 11
        var snapshot = TelegramCacheSnapshot(accountID:11,items:[])
        var scanCallback: (@MainActor (TelegramCacheSnapshot?) -> Void)?
        var completion: (@MainActor (TelegramCacheEvent) -> Void)?
        var holdScan = false, holdClear = false, changeBeforeClear = false, occupied = false
        var removals: [Int64] = []
        func scan(receive: @escaping @MainActor (TelegramCacheSnapshot?) -> Void) -> any TelegramCacheRequest {
            if holdScan { scanCallback = receive } else { receive(snapshot) }; return Request()
        }
        func clear(expected:TelegramCacheSnapshot,categories:Set<TelegramCacheKind>,permitted:@escaping @MainActor () -> Bool,receive:@escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest {
            XCTFail("Maintenance must never broaden exact selection to categories"); return Request()
        }
        func evict(expected:TelegramCacheSnapshot,items:[TelegramCacheItem],permitted:@escaping @MainActor () -> Bool,receive:@escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest {
            if changeBeforeClear { snapshot = .init(accountID:accountID,items:[]) }
            guard expected == snapshot else { receive(.changed(snapshot)); return Request() }
            guard permitted() else { receive(.refused); return Request() }
            removals += items.map(\.id); receive(.committing); completion = receive
            if !holdClear { if !occupied { snapshot = .init(accountID:accountID,items:[]) }; receive(.finished(snapshot)) }; return Request()
        }
    }
    private func maintenance(_ provider: Provider) -> TelegramCacheMaintenance {
        let defaults = UserDefaults(suiteName:"Makosh.Cache.Tests.\(UUID())")!
        let service = TelegramCacheMaintenance(defaults:defaults,now:{ 100_000 })
        service.permitsClear = { true }; service.bind(provider:provider)
        return service
    }
    func testChangedScanRefusesRemoval() {
        let provider = Provider(); provider.snapshot = .init(accountID:11,items:[item(1)])
        let service = maintenance(provider); provider.changeBeforeClear = true
        XCTAssertTrue(service.update(.init(days:1)))
        XCTAssertEqual(provider.removals,[]); XCTAssertNotNil(service.status); XCTAssertFalse(service.isRunning)
    }
    func testRebindRejectsStaleCompletion() {
        let provider = Provider(); provider.snapshot = .init(accountID:11,items:[item(1)]); provider.holdClear = true
        let service = maintenance(provider); XCTAssertTrue(service.update(.init(days:1)))
        XCTAssertTrue(service.isRunning); let callback = provider.completion
        let replacement = Provider(); replacement.accountID = 22; replacement.snapshot = .init(accountID:22,items:[])
        service.bind(provider:replacement)
        callback?(.finished(.init(accountID:11,items:[])))
        XCTAssertEqual(service.accountID,22); XCTAssertNil(service.lastSnapshot); XCTAssertFalse(service.isRunning)
    }
    func testPermissionIsRecheckedAfterAsyncScanAndDisabledPreferenceCancelsPending() {
        let provider = Provider(); provider.snapshot = .init(accountID:11,items:[item(1)]); provider.holdScan = true
        let service = maintenance(provider); XCTAssertTrue(service.update(.init(days:1))); let scan = provider.scanCallback
        service.permitsClear = { false }; scan?(provider.snapshot)
        XCTAssertEqual(provider.removals,[]); XCTAssertFalse(service.isRunning)
        service.permitsClear = { true }; service.run(); let pending = provider.scanCallback
        XCTAssertTrue(service.update(.init())); pending?(provider.snapshot)
        XCTAssertEqual(provider.removals,[]); XCTAssertFalse(service.isRunning)
    }
    func testAccountPreferencesDoNotLeakToReplacementAccount() {
        let provider = Provider(), service = maintenance(Provider())
        XCTAssertTrue(service.update(.init(days:7,limitGB:5)))
        provider.accountID = 22; provider.snapshot = .init(accountID:22,items:[]); service.bind(provider:provider)
        XCTAssertEqual(service.preferences,.init())
        provider.accountID = 11; provider.snapshot = .init(accountID:11,items:[]); service.bind(provider:provider)
        XCTAssertEqual(service.preferences,.init(days:7,limitGB:5))
    }
    func testProtectedUnknownBytesAboveLimitAreReportedAfterClear() {
        let provider = Provider(); provider.occupied = true
        provider.snapshot = .init(accountID:11,items:[item(1,bytes:1,time:1),item(2,bytes:6_000_000_000,time:nil)])
        let service = maintenance(provider)
        XCTAssertTrue(service.update(.init(limitGB:5)))
        XCTAssertEqual(service.lastSnapshot?.totalBytes,6_000_000_001)
        XCTAssertEqual(service.limitExceeded,true)
    }
    func testSchedulerDoesNotKeepItsOwnerAlive() async {
        var service: TelegramCacheMaintenance? = maintenance(Provider())
        XCTAssertTrue(service!.update(.init(days:7)))
        weak var weakService = service
        await Task.yield(); service = nil; await Task.yield()
        XCTAssertNil(weakService)
    }
}
