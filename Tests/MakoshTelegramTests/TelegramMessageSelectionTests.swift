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

    func testShiftAddsCachedHalfOpenRangeAndPreservesFrozenPriorSelection() throws {
        let c = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(c.begin(source: source(2), contextID: context)); let id = try XCTUnwrap(c.session?.id)
        XCTAssertTrue(c.toggle(source: source(8), sessionID: id, contextID: context, extendingRange: true))
        let request = try XCTUnwrap(c.rangeRequest)
        XCTAssertEqual(request.lowerBound, 2); XCTAssertEqual(request.upperBoundExclusive, 8)
        XCTAssertTrue(c.applyRange(sources: [source(2, fingerprint: "new"),source(4),source(6, allowed: false),source(7, namespace: 1)], request: request))
        XCTAssertEqual(c.session?.sources.map(\.messageID), [2,4,6,8,7])
        XCTAssertEqual(c.session?.sources.first?.fingerprint, "version")
        XCTAssertFalse(c.session?.canForward == true); XCTAssertFalse(c.isResolvingRange)
        XCTAssertEqual(c.session?.lastSelectedID?.messageID, 2)
        XCTAssertTrue(c.toggle(source: source(8), sessionID: id, contextID: context, extendingRange: true))
        XCTAssertNil(c.rangeRequest); XCTAssertEqual(c.session?.lastSelectedID?.messageID, 2)
        XCTAssertTrue(c.contains(source(4)))
    }
    func testRangeFillsDescendingUntilCapWithoutRemovingEndpointOrPriorItems() throws {
        let c = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(c.begin(source: source(1), contextID: context)); let id = try XCTUnwrap(c.session?.id)
        XCTAssertTrue(c.toggle(source: source(150), sessionID: id, contextID: context, extendingRange: true))
        let request = try XCTUnwrap(c.rangeRequest)
        XCTAssertTrue(c.applyRange(sources: (1..<150).map { source(Int32($0)) }, request: request))
        XCTAssertEqual(c.session?.count, 100); XCTAssertNotNil(c.error)
        XCTAssertTrue(c.contains(source(1))); XCTAssertTrue(c.contains(source(150)))
        XCTAssertTrue(c.contains(source(52))); XCTAssertFalse(c.contains(source(51)))
        XCTAssertFalse(c.applyRange(sources: [], request: request))
    }
    func testRangeFailureStaleRevisionAndAnchorRules() throws {
        let c = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(c.begin(source: source(2), contextID: context, extendingRange: true))
        XCTAssertNil(c.session?.lastSelectedID)
        let id = try XCTUnwrap(c.session?.id)
        XCTAssertTrue(c.toggle(source: source(8), sessionID: id, contextID: context, extendingRange: true))
        XCTAssertNil(c.rangeRequest)
        XCTAssertTrue(c.toggle(source: source(3), sessionID: id, contextID: context))
        XCTAssertEqual(c.session?.lastSelectedID?.messageID, 3)
        XCTAssertTrue(c.toggle(source: source(10), sessionID: id, contextID: context, extendingRange: true))
        let old = try XCTUnwrap(c.rangeRequest)
        c.observe(sources: [source(3, fingerprint: "changed")], contextID: context, chatID: 7)
        XCTAssertNil(c.rangeRequest); XCTAssertFalse(c.applyRange(sources: [source(4)], request: old))
        XCTAssertTrue(c.toggle(source: source(12), sessionID: id, contextID: context, extendingRange: true))
        let foreign = try XCTUnwrap(c.rangeRequest)
        XCTAssertFalse(c.applyRange(sources: [source(4, account: 2)], request: foreign))
        XCTAssertNotNil(c.error); XCTAssertTrue(c.contains(source(12)))
        XCTAssertTrue(c.toggle(source: source(14), sessionID: id, contextID: context, extendingRange: true))
        let cancelled = try XCTUnwrap(c.rangeRequest)
        XCTAssertTrue(c.toggle(source: source(8), sessionID: id, contextID: context))
        XCTAssertNil(c.rangeRequest); XCTAssertEqual(c.session?.lastSelectedID?.messageID, 10)
        c.failRange(request: cancelled); XCTAssertNil(c.error)
    }

    func testDownwardRangeDedupAndCloudPreferenceAtCapacity() throws {
        let c = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(c.begin(source: source(101), contextID: context)); let id = try XCTUnwrap(c.session?.id)
        for n in 200...296 { XCTAssertTrue(c.toggle(source: source(Int32(n)), sessionID: id, contextID: context, extendingRange: true)) }
        XCTAssertTrue(c.toggle(source: source(1), sessionID: id, contextID: context, extendingRange: true))
        let request = try XCTUnwrap(c.rangeRequest)
        XCTAssertEqual(request.lowerBound, 1); XCTAssertEqual(request.upperBoundExclusive, 101)
        XCTAssertTrue(c.applyRange(sources: [source(100, namespace: 1),source(100),source(100)], request: request))
        XCTAssertEqual(c.session?.count, 100)
        XCTAssertTrue(c.contains(source(100))); XCTAssertFalse(c.contains(source(100, namespace: 1)))
        XCTAssertNotNil(c.error)
    }

    func testRangeReadInvalidatesChangedOffPageSourceWithoutReplacingFrozenBytes() throws {
        let c = TelegramMessageSelectionController(), context = UUID(), original = source(2, fingerprint: "é")
        XCTAssertTrue(c.begin(source: original, contextID: context))
        let id = try XCTUnwrap(c.session?.id)
        XCTAssertTrue(c.toggle(source: source(8), sessionID: id, contextID: context, extendingRange: true))
        XCTAssertTrue(c.applyRange(sources: [source(2, fingerprint: "e\u{301}"), source(4)], request: try XCTUnwrap(c.rangeRequest)))
        XCTAssertEqual(c.session?.sources.map(\.messageID), [2, 4, 8])
        XCTAssertTrue(try XCTUnwrap(c.session?.sources.first).fingerprint.utf8.elementsEqual(original.fingerprint.utf8))
        XCTAssertEqual(c.session?.invalidIDs, [TelegramMessageSelectionID(source: original)])
        XCTAssertFalse(try XCTUnwrap(c.session).canForward)
        c.observe(sources: [original], contextID: context, chatID: 7)
        XCTAssertFalse(try XCTUnwrap(c.session).canForward)
    }

    func testIndependentActionPermissionsAndStickyChanges() throws {
        func item(copy: Bool = true, forward: Bool = true, local: Bool = true, everyone: Bool = true, fingerprint: String = "same") -> TelegramMessageActionSource {
            .init(accountID: 1, chatID: 7, peerID: 7, namespace: 0, messageID: 1,
                  fingerprint: fingerprint, text: "text", canReply: true, canEdit: false,
                  canForward: forward, canDeleteLocally: local, canDeleteForEveryone: everyone, canCopy: copy)
        }
        let c = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(c.begin(source: item(), contextID: context))
        c.observe(sources: [item(copy: false)], contextID: context, chatID: 7)
        let noCopy = try XCTUnwrap(c.session)
        XCTAssertFalse(noCopy.canCopy); XCTAssertTrue(noCopy.canForward)
        XCTAssertTrue(noCopy.canDeleteLocally); XCTAssertTrue(noCopy.canDeleteForEveryone)
        c.observe(sources: [item()], contextID: context, chatID: 7)
        XCTAssertFalse(try XCTUnwrap(c.session).canCopy)
        c.observe(sources: [item(local: false)], contextID: context, chatID: 7)
        XCTAssertFalse(try XCTUnwrap(c.session).canDeleteLocally)
        XCTAssertTrue(try XCTUnwrap(c.session).canDeleteForEveryone)
        c.observe(sources: [item(fingerprint: "changed")], contextID: context, chatID: 7)
        let changed = try XCTUnwrap(c.session)
        XCTAssertFalse(changed.canCopy); XCTAssertFalse(changed.canForward)
        XCTAssertFalse(changed.canDeleteLocally); XCTAssertFalse(changed.canDeleteForEveryone)
    }

    func testUnchangedProtectedSourceStillAllowsDeletionAfterObservation() throws {
        let c = TelegramMessageSelectionController(), context = UUID(), protected = source(1, allowed: false)
        XCTAssertTrue(c.begin(source: protected, contextID: context))
        let revision = c.session?.revision
        c.observe(sources: [protected], contextID: context, chatID: 7)
        let session = try XCTUnwrap(c.session)
        XCTAssertFalse(session.canCopy); XCTAssertFalse(session.canForward)
        XCTAssertTrue(session.canDeleteLocally); XCTAssertEqual(session.revision, revision)
        c.cancel()
        XCTAssertTrue(c.begin(source: source(1, peer: 1, chat: 1), contextID: context))
        XCTAssertFalse(try XCTUnwrap(c.session).canDeleteForEveryone)
    }

}
