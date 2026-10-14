import XCTest
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramReferencePresentationTests: XCTestCase {
    func testAudioPreferencesRoundTripAndRejectUnsupportedOrUnsafeUIDs() throws {
        let selection = TelegramCallAudioSelection(inputUID: "qa-input", outputUID: "qa-output")
        XCTAssertEqual(try .decode(selection.encoded()), selection)
        XCTAssertEqual(try TelegramCallAudioSelection.decode(""), .init())
        XCTAssertThrowsError(try TelegramCallAudioSelection.decode("{\"version\":2,\"inputUID\":\"\",\"outputUID\":\"\"}"))
        XCTAssertThrowsError(try TelegramCallAudioSelection.decode("not-json"))
        XCTAssertFalse(TelegramCallAudioSelection(inputUID: String(repeating: "x", count: 128)).isValid)
        XCTAssertFalse(TelegramCallAudioSelection(outputUID: "device\nother").isValid)
    }
    func testAdminFilterUsesExactPinnedFlagsAndRejectsEmptySelection() {
        let filter = TelegramAdminHistoryFilter(kinds: [.editMessages, .deleteMessages, .calls], adminIDs: [42, 43])
        XCTAssertEqual(filter.nativeFlags, 28_672)
        XCTAssertTrue(filter.isValid)
        XCTAssertNil(TelegramAdminHistoryFilter.all.nativeFlags)
        XCTAssertFalse(TelegramAdminHistoryFilter(kinds: []).isValid)
        XCTAssertFalse(TelegramAdminHistoryFilter(adminIDs: [0]).isValid)
        XCTAssertFalse(TelegramAdminHistoryFilter(adminIDs: [4_294_967_338]).isValid)
        XCTAssertFalse(TelegramAdminHistoryFilter(adminIDs: Set(1...101).map(Int64.init).reduce(into: Set<Int64>()) { $0.insert($1) }).isValid)
        XCTAssertEqual(TelegramAdminEventKind.allCases.reduce(UInt32(0)) { $0 | $1.rawValue }, AdminLogEventsFlags.all.rawValue)
    }
    func testProtectedEventCannotOfferCopyButRetainsVisibleKnownText() {
        var event = TelegramGroupAdminEvent(id: 1, actorID: 42, actor: "QA", summary: "Изменено", date: 1, previousText: "До", currentText: "После")
        XCTAssertTrue(event.allowsCopy)
        event.copyProtected = true
        XCTAssertFalse(event.allowsCopy)
        XCTAssertEqual(event.previousText, "До")
        XCTAssertEqual(event.currentText, "После")
    }
    func testFilterStartsFreshPageAndRejectsLateResultAndStaleEditor() {
        let provider = PresentationGroupProvider(), controller = TelegramGroupMembershipController()
        controller.bind(provider); controller.open(peerID: provider.snapshot.peerID)
        provider.reads[0].receive(.success(.init(snapshot: provider.snapshot)))
        XCTAssertTrue(controller.show(.history))
        let old = controller.contextID, oldRead = provider.reads[1]
        let filter = TelegramAdminHistoryFilter(kinds: [.deleteMessages], adminIDs: [42])
        XCTAssertTrue(controller.filterHistory(filter, contextID: old))
        XCTAssertNotEqual(controller.contextID, old)
        XCTAssertEqual(provider.reads.last?.filter, filter)
        XCTAssertNil(provider.reads.last?.cursor)
        oldRead.receive(.success(.init(snapshot: provider.snapshot)))
        XCTAssertEqual(controller.status, .loading)
        XCTAssertFalse(controller.filterHistory(.all, contextID: old))
        provider.reads.last?.receive(.success(.init(snapshot: provider.snapshot)))
        XCTAssertEqual(controller.status, .ready)
        XCTAssertFalse(controller.filterHistory(.init(kinds: []), contextID: controller.contextID))
        controller.close(); XCTAssertEqual(controller.historyFilter, .all)
    }
    func testFilteredHistoryRefusesUnexpectedAuthorWithoutPublishingRows() {
        let provider = PresentationGroupProvider(), controller = TelegramGroupMembershipController()
        controller.bind(provider); controller.open(peerID: provider.snapshot.peerID)
        provider.reads[0].receive(.success(.init(snapshot: provider.snapshot)))
        XCTAssertTrue(controller.show(.history))
        XCTAssertTrue(controller.filterHistory(.init(adminIDs: [42]), contextID: controller.contextID))
        provider.reads.last?.receive(.success(.init(snapshot: provider.snapshot, events: [
            .init(id: 1, actorID: 43, actor: "Other QA", summary: "QA", date: 1, previousText: nil, currentText: nil)
        ])))
        XCTAssertEqual(controller.status, .failed); XCTAssertTrue(controller.events.isEmpty)
    }
    func testRecallUsesNewIdentityAndRefusesRetiringOrDifferentPeer() async throws {
        let controller = TelegramCallController(permissions: TelegramSyntheticCallPermissions(), coordinator: TelegramCallCoordinator())
        controller.bind(TelegramSyntheticCallProvider()); controller.selectPeer(42)
        let peer = try XCTUnwrap(controller.peer)
        XCTAssertTrue(controller.startOutgoing(basis: peer, video: false, contextID: controller.peerContextID))
        for _ in 0..<100 { if controller.call?.phase == .requesting { break }; try await Task.sleep(for: .milliseconds(20)) }
        let id = try XCTUnwrap(controller.call?.id)
        controller.end(callID: id)
        XCTAssertFalse(controller.recall(callID: id, video: false))
        for _ in 0..<100 { if !controller.isReleasingMedia { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(controller.canRecall(callID: id))
        controller.selectPeer(43); XCTAssertFalse(controller.canRecall(callID: id))
        controller.selectPeer(42); XCTAssertTrue(controller.recall(callID: id, video: false))
        XCTAssertNotEqual(controller.call?.id, id)
        XCTAssertFalse(controller.recall(callID: id, video: false))
        if let next = controller.call?.id { controller.end(callID: next) }
    }
}

@MainActor private final class PresentationRead: TelegramGroupMembershipRequest { func cancel() {} }
@MainActor private final class PresentationGroupProvider: TelegramGroupMembershipProvider {
    let accountID: Int64 = 101
    let snapshot = TelegramGroupMembershipSnapshot(accountID: 101, peerID: 8_589_934_634, title: "QA", basic: false, isCreator: true, canInvite: true, canManageLinks: true, canRequests: true, canHistory: true)
    struct Read {
        let filter: TelegramAdminHistoryFilter, cursor: TelegramGroupMembershipCursor?
        let receive: @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void
    }
    var reads: [Read] = []
    func load(peerID: Int64, page: TelegramGroupMembershipSection, ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?, receive: @escaping @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void) -> any TelegramGroupMembershipRequest {
        load(peerID: peerID, page: page, ownerID: ownerID, query: query, cursor: cursor, historyFilter: .all, receive: receive)
    }
    func load(peerID: Int64, page: TelegramGroupMembershipSection, ownerID: Int64?, query: String, cursor: TelegramGroupMembershipCursor?, historyFilter: TelegramAdminHistoryFilter, receive: @escaping @MainActor (Result<TelegramGroupMembershipPage, TelegramGroupMembershipError>) -> Void) -> any TelegramGroupMembershipRequest {
        reads.append(.init(filter: historyFilter, cursor: cursor, receive: receive)); return PresentationRead()
    }
    func apply(basis: TelegramGroupMembershipSnapshot, change: TelegramGroupMembershipChange, receive: @escaping @MainActor (TelegramGroupMembershipEvent) -> Bool) -> any TelegramGroupMembershipRequest { PresentationRead() }
}
