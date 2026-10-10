import XCTest
import Postbox
@testable import MakoshTelegram

@MainActor final class TelegramMessageSelectionTests: XCTestCase {
    private func source(_ id: Int32, peer: Int64 = 7, account: Int64 = 1, chat: Int64 = 7,
                        fingerprint: String = "version", allowed: Bool = true, namespace: Int32 = 0) -> TelegramMessageActionSource {
        .init(accountID: account, chatID: chat, peerID: peer, namespace: namespace, messageID: id,
              fingerprint: fingerprint, text: "synthetic", canReply: true, canEdit: false,
              canForward: allowed, canDeleteLocally: true, canDeleteForEveryone: false)
    }
    func testNativeOrderingAndBoundPreserveSelectionOnRefusal() throws {
        let c = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(c.begin(source: source(100), contextID: context))
        let id = try XCTUnwrap(c.session?.id)
        for n in (1...99).reversed() { XCTAssertTrue(c.toggle(source: source(Int32(n)), sessionID: id, contextID: context)) }
        XCTAssertEqual(c.session?.sources.map(\.messageID), (1...100).map(Int32.init))
        XCTAssertFalse(c.toggle(source: source(101), sessionID: id, contextID: context))
        XCTAssertEqual(c.session?.count, 100); XCTAssertNotNil(c.error)
        XCTAssertTrue(c.toggle(source: source(50), sessionID: id, contextID: context)); XCTAssertNil(c.error)
        XCTAssertTrue(c.toggle(source: source(101), sessionID: id, contextID: context))
        let native = try XCTUnwrap(c.session).sources.map { MessageId(peerId: PeerId($0.peerID), namespace: $0.namespace, id: $0.messageID) }
        XCTAssertEqual(native, native.sorted())
    }
    func testStaleScopeAndInvalidCloudAdmission() throws {
        let c = TelegramMessageSelectionController(), context = UUID()
        XCTAssertFalse(c.begin(source: source(0), contextID: context))
        XCTAssertFalse(c.begin(source: source(1, namespace: 1), contextID: context))
        XCTAssertTrue(c.begin(source: source(1), contextID: context))
        let id = try XCTUnwrap(c.session?.id), snapshot = c.session
        for other in [source(2, account: 2), source(2, chat: 8)] {
            XCTAssertFalse(c.toggle(source: other, sessionID: id, contextID: context))
        }
        XCTAssertFalse(c.toggle(source: source(2), sessionID: UUID(), contextID: context))
        XCTAssertFalse(c.toggle(source: source(2), sessionID: id, contextID: UUID()))
        XCTAssertEqual(c.session, snapshot); XCTAssertFalse(c.contains(source(1, account: 2)))
        c.cancel(); XCTAssertNil(c.session)
        XCTAssertTrue(c.begin(source: source(1), contextID: context)); XCTAssertNotEqual(c.session?.id, id)
    }
    func testFrozenExactBytesStickyInvalidationAndReselect() throws {
        let c = TelegramMessageSelectionController(), context = UUID(), original = source(1, fingerprint: "é")
        XCTAssertTrue(c.begin(source: original, contextID: context)); let id = try XCTUnwrap(c.session?.id)
        c.observe(sources: [], contextID: context, chatID: 7)
        XCTAssertTrue(c.session?.canForward == true)
        c.observe(sources: [source(1, fingerprint: "e\u{301}")], contextID: UUID(), chatID: 7)
        XCTAssertTrue(c.session?.canForward == true)
        c.observe(sources: [source(1, fingerprint: "e\u{301}")], contextID: context, chatID: 7)
        XCTAssertFalse(c.session?.canForward == true)
        XCTAssertTrue(try XCTUnwrap(c.session?.sources.first).fingerprint.utf8.elementsEqual(original.fingerprint.utf8))
        c.observe(sources: [original], contextID: context, chatID: 7)
        XCTAssertEqual(c.session?.invalidIDs.count, 1)
        XCTAssertTrue(c.toggle(source: source(1, fingerprint: "changed"), sessionID: id, contextID: context))
        XCTAssertEqual(c.session?.count, 0); XCTAssertNotNil(c.session); XCTAssertFalse(c.session?.canForward == true)
        XCTAssertTrue(c.toggle(source: original, sessionID: id, contextID: context)); XCTAssertTrue(c.session?.canForward == true)
    }
    func testProtectedSelectionAndVisiblePermissionOrScopeChange() throws {
        let c = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(c.begin(source: source(1, allowed: false), contextID: context))
        XCTAssertFalse(c.session?.canForward == true); XCTAssertTrue(c.contains(source(1)))
        let id = try XCTUnwrap(c.session?.id)
        XCTAssertTrue(c.toggle(source: source(1), sessionID: id, contextID: context))
        XCTAssertTrue(c.toggle(source: source(2), sessionID: id, contextID: context))
        c.observe(sources: [source(2, allowed: false)], contextID: context, chatID: 7)
        XCTAssertEqual(c.session?.invalidIDs.count, 1)
        c.observe(sources: [], contextID: context, chatID: 7); XCTAssertEqual(c.session?.invalidIDs.count, 1)
        XCTAssertTrue(c.toggle(source: source(2), sessionID: id, contextID: context))
        XCTAssertTrue(c.toggle(source: source(3), sessionID: id, contextID: context))
        c.observe(sources: [source(3, account: 2)], contextID: context, chatID: 7)
        XCTAssertEqual(c.session?.invalidIDs.count, 1)
    }
    func testRevisionTracksSelectionAndNewInvalidationOnly() throws {
        let c = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(c.begin(source: source(1), contextID: context))
        let initial = try XCTUnwrap(c.session)
        c.observe(sources: [], contextID: context, chatID: 7)
        XCTAssertEqual(c.session?.revision, initial.revision)
        XCTAssertTrue(c.toggle(source: source(2), sessionID: initial.id, contextID: context))
        let toggled = try XCTUnwrap(c.session?.revision)
        XCTAssertNotEqual(toggled, initial.revision)
        c.observe(sources: [source(1, fingerprint: "changed")], contextID: context, chatID: 7)
        let invalidated = try XCTUnwrap(c.session?.revision)
        XCTAssertNotEqual(invalidated, toggled)
        c.observe(sources: [source(1, fingerprint: "changed")], contextID: context, chatID: 7)
        XCTAssertEqual(c.session?.revision, invalidated)
        c.observe(sources: [], contextID: context, chatID: 7)
        XCTAssertEqual(c.session?.revision, invalidated)
    }

}
