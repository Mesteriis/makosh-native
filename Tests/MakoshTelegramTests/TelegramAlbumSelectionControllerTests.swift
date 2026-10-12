import XCTest
import Combine
@testable import MakoshTelegram

@MainActor final class TelegramAlbumSelectionControllerTests: XCTestCase {
    private func source(_ id: Int32, account: Int64 = 1, chat: Int64 = 7, peer: Int64 = 7,
                        fingerprint: String = "version", allowed: Bool = true,
                        namespace: Int32 = 0) -> TelegramMessageActionSource {
        .init(accountID: account, chatID: chat, peerID: peer, namespace: namespace, messageID: id,
              fingerprint: fingerprint, text: "synthetic \(id)", canReply: true, canEdit: false,
              canForward: allowed, canDeleteLocally: true, canDeleteForEveryone: true, canCopy: true)
    }

    private func seeded(_ count: Int, context: UUID) throws -> TelegramMessageSelectionController {
        let controller = TelegramMessageSelectionController()
        XCTAssertTrue(controller.begin(source: source(1), contextID: context))
        let id = try XCTUnwrap(controller.session?.id)
        if count > 1 {
            for value in 2...count {
                XCTAssertTrue(controller.toggle(source: source(Int32(value)), sessionID: id, contextID: context))
            }
        }
        return controller
    }

    func testBeginGroupPublishesOneSessionWithNativeOrderAndLastInputAnchor() throws {
        let controller = TelegramMessageSelectionController(), context = UUID()
        var sessions: [TelegramMessageSelectionSession?] = []
        let observation = controller.$session.dropFirst().sink { sessions.append($0) }
        XCTAssertTrue(controller.beginGroup(sources: [source(9), source(3), source(7)], contextID: context))
        let session = try XCTUnwrap(controller.session)
        XCTAssertEqual(session.contextID, context)
        XCTAssertEqual(session.sources.map(\.messageID), [3, 7, 9])
        XCTAssertEqual(session.lastSelectedID?.messageID, 7)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(session.canForward && session.canCopy && session.canDeleteLocally && session.canDeleteForEveryone)
        XCTAssertNil(controller.rangeRequest)
        withExtendedLifetime(observation) {}
    }

    func testBeginGroupAcceptsOneHundredMembersAndProtectedSelection() throws {
        let controller = TelegramMessageSelectionController(), context = UUID()
        let members = (1...100).reversed().map { source(Int32($0), allowed: $0 != 50) }
        XCTAssertTrue(controller.beginGroup(sources: members, contextID: context))
        XCTAssertEqual(controller.session?.count, 100)
        XCTAssertEqual(controller.session?.sources.map(\.messageID), (1...100).map(Int32.init))
        XCTAssertEqual(controller.session?.lastSelectedID?.messageID, 1)
        XCTAssertFalse(controller.session?.canForward == true)
        XCTAssertTrue(controller.session?.canCopy == true)
    }

    func testInvalidBeginGroupDoesNotReplaceSessionOrCancelPendingRange() throws {
        let controller = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(controller.begin(source: source(2), contextID: context))
        let id = try XCTUnwrap(controller.session?.id)
        XCTAssertTrue(controller.toggle(source: source(8), sessionID: id, contextID: context, extendingRange: true))
        let snapshot = controller.session, request = try XCTUnwrap(controller.rangeRequest)
        let invalid: [[TelegramMessageActionSource]] = [
            [], [source(2)], (1...101).map { source(Int32($0)) },
            [source(2), source(2)], [source(2), source(0)],
            [source(2), source(3, namespace: 1)], [source(2), source(3, fingerprint: "")],
            [source(2), source(3, account: 2)], [source(2), source(3, chat: 8)]
        ]
        for members in invalid {
            XCTAssertFalse(controller.beginGroup(sources: members, contextID: context))
            XCTAssertEqual(controller.session, snapshot)
            XCTAssertEqual(controller.rangeRequest, request)
            XCTAssertTrue(controller.isResolvingRange)
        }
    }

    func testPartialGroupAddsOnlyMissingMembersAndPreservesFrozenInvalidation() throws {
        let controller = TelegramMessageSelectionController(), context = UUID(), frozen = source(2, fingerprint: "é")
        XCTAssertTrue(controller.begin(source: frozen, contextID: context))
        controller.observe(sources: [source(2, fingerprint: "e\u{301}")], contextID: context, chatID: 7)
        let snapshot = try XCTUnwrap(controller.session)
        var revisions: [UUID] = []
        let observation = controller.$session.dropFirst().sink { if let value = $0 { revisions.append(value.revision) } }
        XCTAssertTrue(controller.toggleGroup(sources: [source(2), source(6), source(4)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision))
        let next = try XCTUnwrap(controller.session)
        XCTAssertEqual(next.sources.map(\.messageID), [2, 4, 6])
        XCTAssertEqual(next.sources.first, frozen)
        XCTAssertTrue(try XCTUnwrap(next.sources.first).fingerprint.utf8.elementsEqual(frozen.fingerprint.utf8))
        XCTAssertEqual(next.invalidActions, snapshot.invalidActions)
        XCTAssertFalse(next.canForward || next.canCopy || next.canDeleteLocally || next.canDeleteForEveryone)
        XCTAssertEqual(next.lastSelectedID?.messageID, 4)
        XCTAssertEqual(revisions, [next.revision])
        XCTAssertNotEqual(next.revision, snapshot.revision)
        withExtendedLifetime(observation) {}
    }

    func testFreshPartialMemberPermissionLossInvalidatesWithoutReplacingFrozenSource() throws {
        let controller = TelegramMessageSelectionController(), context = UUID(), frozen = source(2)
        XCTAssertTrue(controller.begin(source: frozen, contextID: context))
        let snapshot = try XCTUnwrap(controller.session)
        XCTAssertTrue(controller.toggleGroup(sources: [source(2, allowed: false), source(4)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision))
        let next = try XCTUnwrap(controller.session)
        XCTAssertEqual(next.sources.first, frozen)
        XCTAssertEqual(next.invalidActions[.init(source: frozen)], [.forward])
        XCTAssertFalse(next.canForward)
        XCTAssertTrue(next.canCopy && next.canDeleteLocally && next.canDeleteForEveryone)
        controller.observe(sources: [frozen], contextID: context, chatID: 7)
        XCTAssertEqual(controller.session?.invalidActions, next.invalidActions)
    }

    func testFullGroupRemovesExactMembersAndUsesGreaterSelectedAnchorFallback() throws {
        let context = UUID(), controller = try seeded(10, context: context)
        controller.observe(sources: [source(4, allowed: false), source(10, allowed: false)], contextID: context, chatID: 7)
        var snapshot = try XCTUnwrap(controller.session)
        XCTAssertTrue(controller.toggleGroup(sources: [source(4), source(6)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision))
        XCTAssertEqual(controller.session?.sources.map(\.messageID), [1, 2, 3, 5, 7, 8, 9, 10])
        XCTAssertEqual(controller.session?.lastSelectedID?.messageID, 7)
        XCTAssertNil(controller.session?.invalidActions[.init(source: source(4))])
        XCTAssertEqual(controller.session?.invalidActions[.init(source: source(10))], [.forward])
        snapshot = try XCTUnwrap(controller.session)
        XCTAssertTrue(controller.toggleGroup(sources: [source(9), source(10)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision))
        XCTAssertEqual(controller.session?.lastSelectedID?.messageID, 10)
        XCTAssertEqual(controller.session?.sources.map(\.messageID), [1, 2, 3, 5, 7, 8])
        XCTAssertTrue(controller.session?.invalidActions.isEmpty == true)
    }

    func testStaleOrForeignGroupRefusesAtomicallyAndKeepsPendingRange() throws {
        let controller = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(controller.begin(source: source(2), contextID: context))
        let initial = try XCTUnwrap(controller.session)
        XCTAssertTrue(controller.toggle(source: source(8), sessionID: initial.id, contextID: context, extendingRange: true))
        let snapshot = try XCTUnwrap(controller.session), request = try XCTUnwrap(controller.rangeRequest)
        XCTAssertFalse(controller.toggleGroup(sources: [source(4), source(6)], sessionID: snapshot.id,
            contextID: context, expectedRevision: initial.revision))
        XCTAssertFalse(controller.toggleGroup(sources: [source(4), source(6)], sessionID: UUID(),
            contextID: context, expectedRevision: snapshot.revision))
        XCTAssertFalse(controller.toggleGroup(sources: [source(4), source(6)], sessionID: snapshot.id,
            contextID: UUID(), expectedRevision: snapshot.revision))
        let invalid: [[TelegramMessageActionSource]] = [
            [], [source(2)], (1...101).map { source(Int32($0)) }, [source(2), source(2)],
            [source(2), source(4), source(0)], [source(2), source(4, namespace: 1)],
            [source(2), source(4, fingerprint: "")], [source(2), source(4, account: 2)],
            [source(2), source(4, chat: 8)]
        ]
        for members in invalid {
            XCTAssertFalse(controller.toggleGroup(sources: members, sessionID: snapshot.id,
                contextID: context, expectedRevision: snapshot.revision))
        }
        XCTAssertEqual(controller.session, snapshot)
        XCTAssertEqual(controller.rangeRequest, request)
        XCTAssertTrue(controller.isResolvingRange)
    }

    func testPartialCapAddsMissingMembersInInputOrderAndPublishesOnce() throws {
        let context = UUID(), controller = try seeded(98, context: context)
        let snapshot = try XCTUnwrap(controller.session)
        var revisions: [UUID] = []
        let observation = controller.$session.dropFirst().sink { if let value = $0 { revisions.append(value.revision) } }
        XCTAssertTrue(controller.toggleGroup(sources: [source(1), source(202), source(200), source(201)],
            sessionID: snapshot.id, contextID: context, expectedRevision: snapshot.revision))
        XCTAssertEqual(controller.session?.count, 100)
        XCTAssertTrue(controller.contains(source(202)) && controller.contains(source(200)))
        XCTAssertFalse(controller.contains(source(201)))
        XCTAssertEqual(controller.session?.lastSelectedID?.messageID, 200)
        XCTAssertNotNil(controller.error)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertNil(controller.rangeRequest)
        withExtendedLifetime(observation) {}
    }

    func testCapRefusesMissingMembersButFullGroupRemovalStillWorks() throws {
        let context = UUID(), controller = try seeded(100, context: context)
        let snapshot = try XCTUnwrap(controller.session)
        XCTAssertFalse(controller.toggleGroup(sources: [source(1), source(200)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision))
        XCTAssertEqual(controller.session, snapshot)
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(controller.toggleGroup(sources: [source(1), source(100)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision))
        XCTAssertEqual(controller.session?.count, 98)
        XCTAssertFalse(controller.contains(source(1)) || controller.contains(source(100)))
        XCTAssertNil(controller.error)
    }

    func testShiftUsesFirstNewInputEndpointPreservesAnchorAndAppliesExistingRangeContract() throws {
        let controller = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(controller.begin(source: source(2), contextID: context))
        let snapshot = try XCTUnwrap(controller.session)
        XCTAssertTrue(controller.toggleGroup(sources: [source(2), source(8), source(6), source(9)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision, extendingRange: true))
        let next = try XCTUnwrap(controller.session), request = try XCTUnwrap(controller.rangeRequest)
        XCTAssertEqual(next.sources.map(\.messageID), [2, 6, 8, 9])
        XCTAssertEqual(next.lastSelectedID?.messageID, 2)
        XCTAssertEqual(request.anchorID.messageID, 2)
        XCTAssertEqual(request.endpointID.messageID, 8)
        XCTAssertEqual(request.lowerBound, 2)
        XCTAssertEqual(request.upperBoundExclusive, 8)
        XCTAssertEqual(request.sessionID, next.id)
        XCTAssertEqual(request.revision, next.revision)
        XCTAssertEqual(request.contextID, context)
        XCTAssertEqual(request.accountID, 1)
        XCTAssertEqual(request.chatID, 7)
        XCTAssertTrue(controller.isResolvingRange)
        XCTAssertTrue(controller.applyRange(sources: [source(3), source(7)], request: request))
        XCTAssertEqual(controller.session?.sources.map(\.messageID), [2, 3, 6, 7, 8, 9])
        XCTAssertEqual(controller.session?.lastSelectedID?.messageID, 2)
        XCTAssertFalse(controller.isResolvingRange)
    }

    func testShiftBeginHasNoAnchorAndShiftFullRemovalDoesNotCreateRange() throws {
        let controller = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(controller.beginGroup(sources: [source(2), source(4)], contextID: context, extendingRange: true))
        var snapshot = try XCTUnwrap(controller.session)
        XCTAssertNil(snapshot.lastSelectedID)
        XCTAssertTrue(controller.toggleGroup(sources: [source(8), source(9)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision, extendingRange: true))
        XCTAssertNil(controller.session?.lastSelectedID)
        XCTAssertNil(controller.rangeRequest)
        snapshot = try XCTUnwrap(controller.session)
        XCTAssertTrue(controller.toggleGroup(sources: [source(2), source(4)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision, extendingRange: true))
        XCTAssertEqual(controller.session?.sources.map(\.messageID), [8, 9])
        XCTAssertNil(controller.session?.lastSelectedID)
        XCTAssertNil(controller.rangeRequest)
    }

    func testShiftRemovalPreservesAnchorEvenWhenAnchorIsRemoved() throws {
        let controller = TelegramMessageSelectionController(), context = UUID()
        XCTAssertTrue(controller.beginGroup(sources: [source(2), source(8)], contextID: context))
        let snapshot = try XCTUnwrap(controller.session)
        XCTAssertTrue(controller.toggleGroup(sources: [source(2), source(8)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision, extendingRange: true))
        XCTAssertEqual(controller.session?.count, 0)
        XCTAssertEqual(controller.session?.lastSelectedID?.messageID, 8)
        XCTAssertNil(controller.rangeRequest)
        XCTAssertFalse(controller.isResolvingRange)
    }

    func testShiftReachingCapKeepsAnchorWithoutRangeRead() throws {
        let context = UUID(), controller = try seeded(99, context: context)
        let snapshot = try XCTUnwrap(controller.session)
        XCTAssertTrue(controller.toggleGroup(sources: [source(200), source(201)], sessionID: snapshot.id,
            contextID: context, expectedRevision: snapshot.revision, extendingRange: true))
        XCTAssertEqual(controller.session?.count, 100)
        XCTAssertEqual(controller.session?.lastSelectedID, snapshot.lastSelectedID)
        XCTAssertTrue(controller.contains(source(200)))
        XCTAssertFalse(controller.contains(source(201)))
        XCTAssertNil(controller.rangeRequest)
        XCTAssertFalse(controller.isResolvingRange)
    }
}
