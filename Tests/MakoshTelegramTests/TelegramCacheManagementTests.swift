import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramCacheManagementTests: XCTestCase {
    static func snapshot() -> TelegramCacheSnapshot {
        .init(accountID:11,items:[
            .init(namespace:0,id:1,bytes:10,kind:.photos,resources:["cloud-a"],peerIDs:[101]),
            .init(namespace:0,id:2,bytes:20,kind:.files,resources:["cloud-b"],peerIDs:[101,102]),
            .init(namespace:0,id:3,bytes:30,kind:.files,resources:["cloud-c"],peerIDs:[102]),
            .init(namespace:0,id:4,bytes:40,kind:.files,resources:["cloud-d"],peerIDs:[])],peerTitles:[101:"Test A",102:"Test B"])
    }
    func testPerChatSelectionExcludesUnknownAndSharedOutsideSelection() {
        let snapshot = Self.snapshot()
        XCTAssertEqual(snapshot.bytes(for:.files,scope:.peers([101])),0)
        XCTAssertEqual(snapshot.bytes(for:.photos,scope:.peers([101])),10)
        XCTAssertEqual(snapshot.bytes(for:.files,scope:.peers([101,102])),50)
        XCTAssertEqual(snapshot.bytes(for:.files,scope:.all),90)
        XCTAssertEqual(snapshot.peers.first { $0.id == 101 }?.sharedBytes,20)
        XCTAssertEqual(snapshot.peers.first { $0.id == 102 }?.exclusiveBytes,30)
        XCTAssertEqual(snapshot.peers.first { $0.id == 101 }?.title,"Test A")
    }
    private final class Request: TelegramCacheRequest { func cancel() {} }
    private final class Provider: TelegramCacheProvider {
        let accountID: Int64 = 11
        var snapshot = TelegramCacheManagementTests.snapshot()
        var scope: TelegramCacheScope?
        var observedExpected: TelegramCacheSnapshot?
        var callback: (@MainActor (TelegramCacheEvent) -> Void)?
        func scan(receive: @escaping @MainActor (TelegramCacheSnapshot?) -> Void) -> any TelegramCacheRequest { receive(snapshot); return Request() }
        func clear(expected:TelegramCacheSnapshot,categories:Set<TelegramCacheKind>,permitted:@escaping @MainActor () -> Bool,receive:@escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest {
            clear(expected:expected,categories:categories,scope:.all,permitted:permitted,receive:receive)
        }
        func clear(expected:TelegramCacheSnapshot,categories:Set<TelegramCacheKind>,scope:TelegramCacheScope,permitted:@escaping @MainActor () -> Bool,receive:@escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest {
            observedExpected = expected; self.scope = scope; callback = receive
            if !permitted() { receive(.refused) }; return Request()
        }
    }
    func testConfirmationRetainsFullFreshBasisAndExactScope() throws {
        let p = Provider(), c = TelegramCacheController(); c.permitsClear = { true }; c.bind(p); c.open()
        let confirmed = try XCTUnwrap(c.prepareClear(categories:[.photos,.files],contextID:c.contextID,scope:.peers([101])))
        XCTAssertEqual(confirmed.byteCount,10)
        XCTAssertTrue(c.confirmClear(confirmed)); XCTAssertEqual(p.scope,.peers([101])); XCTAssertEqual(p.observedExpected,Self.snapshot())
        p.callback?(.changed(Self.snapshot())); XCTAssertFalse(c.confirmClear(confirmed))
    }
    func testBusyOrUnassignedChatCannotAuthorizeSelectiveRemoval() {
        let p = Provider(), c = TelegramCacheController(); var allowed = true
        c.permitsClear = { allowed }; c.bind(p); c.open()
        XCTAssertNil(c.prepareClear(categories:[.files],contextID:c.contextID,scope:.peers([101])))
        XCTAssertNil(c.prepareClear(categories:[.photos],contextID:c.contextID,scope:.peers([])))
        XCTAssertNil(c.prepareClear(categories:[.files],contextID:c.contextID,scope:.peers([999])))
        let confirmation = c.prepareClear(categories:[.photos],contextID:c.contextID,scope:.peers([101]))
        allowed = false
        XCTAssertFalse(confirmation.map(c.confirmClear) ?? true); XCTAssertNil(p.scope)
    }
    func testDuplicateOrZeroPeerOwnershipCannotPublishSnapshot() {
        for peers: [Int64] in [[101,101],[0]] {
            let snapshot = TelegramCacheSnapshot(accountID:11,items:[.init(namespace:0,id:1,bytes:1,kind:.files,resources:["cloud-a"],peerIDs:peers)])
            XCTAssertFalse(snapshot.isValid)
        }
    }
}
