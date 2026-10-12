#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramAlbumSelectionModelTests: XCTestCase {
    private func fixture(members: [Int] = [81, 83]) throws -> TelegramModel {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
        try setMembers(members, model: model)
        return model
    }
    private func setMembers(_ members: [Int], model: TelegramModel) throws {
        var messages = model.messages
        for index in messages.indices {
            guard let number = messages[index].actionMetadata?.messageID else { continue }
            if members.contains(Int(number)) {
                messages[index].albumGroupID = 42
                messages[index].attachments = [.init(id: "album-\(number)", kind: .photo, name: "Synthetic.png",
                    byteCount: nil, mimeType: "image/png", hasPreview: true, canDownload: true)]
            }
        }
        model.receiveMessages(messages, requestID: try XCTUnwrap(model.historyWindowID), previous: nil, next: nil, isLoading: false)
    }
    private func group(_ model: TelegramModel) throws -> TelegramHistoryItem {
        try XCTUnwrap(model.historyItems.first(where: \.isAlbum))
    }
    private func toggle(_ model: TelegramModel, group: TelegramHistoryItem? = nil,
                        revision: UUID? = nil, window: UUID? = nil, context: UUID? = nil) throws -> Bool {
        model.toggleMessageGroupSelection(group: try group ?? self.group(model), sessionID: model.messageSelection.session?.id,
            expectedRevision: revision ?? model.messageSelection.session?.revision,
            contextID: context ?? model.messageActionContextID, windowID: try window ?? XCTUnwrap(model.historyWindowID))
    }

    func testWholePartialAndIndividualSelectionsUseExactMembersAndPreserveInput() throws {
        let model = try fixture(); model.draft = "ordinary 😀"
        let window = try XCTUnwrap(model.historyWindowID), captured = try group(model)
        XCTAssertTrue(try toggle(model, group: captured))
        let first = try XCTUnwrap(model.messageSelection.session)
        XCTAssertEqual(first.sources.map(\.messageID), [81, 83])
        XCTAssertTrue(model.toggleMessageSelection(messageID: "synthetic:10001:81", sessionID: first.id,
            contextID: first.contextID, windowID: window))
        XCTAssertEqual(model.messageSelection.session?.sources.map(\.messageID), [83])
        XCTAssertFalse(try toggle(model, group: captured, revision: first.revision))
        XCTAssertTrue(try toggle(model, group: captured))
        XCTAssertEqual(model.messageSelection.session?.sources.map(\.messageID), [81, 83])
        XCTAssertTrue(try toggle(model, group: captured))
        XCTAssertEqual(model.messageSelection.session?.count, 0)
        XCTAssertEqual(model.draft, "ordinary 😀")
    }

    func testStaleWindowContextAndMembershipCannotChangeSelection() throws {
        let model = try fixture(), captured = try group(model), window = try XCTUnwrap(model.historyWindowID)
        XCTAssertFalse(try toggle(model, group: captured, window: UUID()))
        XCTAssertFalse(try toggle(model, group: captured, context: UUID()))
        XCTAssertTrue(try toggle(model, group: captured))
        let first = try XCTUnwrap(model.messageSelection.session)
        try setMembers([81, 83, 84], model: model)
        XCTAssertEqual(model.messageSelection.session?.sources.map(\.messageID), [81, 83])
        XCTAssertFalse(try toggle(model, group: captured))
        XCTAssertEqual(model.messageSelection.session?.sources, first.sources)
        XCTAssertTrue(try toggle(model))
        XCTAssertEqual(model.messageSelection.session?.sources.map(\.messageID), [81, 83, 84])
        model.loadOlderMessages()
        XCTAssertFalse(try toggle(model, group: captured, window: window))
        XCTAssertEqual(model.messageSelection.session?.sources.map(\.messageID), [81, 83, 84])
    }

    func testChangedMemberRejectsFrozenGroupAndKeepsFrozenSelectionInvalid() throws {
        let model = try fixture(), captured = try group(model)
        XCTAssertTrue(try toggle(model, group: captured))
        let first = try XCTUnwrap(model.messageSelection.session)
        var messages = model.messages
        let index = try XCTUnwrap(messages.firstIndex(where: { $0.actionMetadata?.messageID == 81 }))
        let old = try XCTUnwrap(messages[index].actionMetadata)
        messages[index].actionMetadata = .init(peerID: old.peerID, namespace: old.namespace, messageID: old.messageID,
            fingerprint: "changed-native-version", text: old.text, authorID: old.authorID, canReply: true,
            canEdit: false, canForward: true, canDeleteLocally: true, canDeleteForEveryone: false, canCopy: true)
        model.receiveMessages(messages, requestID: try XCTUnwrap(model.historyWindowID), previous: nil, next: nil, isLoading: false)
        XCTAssertFalse(try toggle(model, group: captured))
        XCTAssertEqual(model.messageSelection.session?.sources, first.sources)
        XCTAssertFalse(try XCTUnwrap(model.messageSelection.session).canForward)
    }

    func testProtectedMemberBlocksForwardButPermitsExactLocalDeleteSelection() throws {
        let model = try fixture(members: [119, 120])
        XCTAssertTrue(try toggle(model))
        let session = try XCTUnwrap(model.messageSelection.session)
        XCTAssertEqual(session.sources.map(\.messageID), [119, 120])
        XCTAssertFalse(session.canForward); XCTAssertFalse(session.canCopy); XCTAssertTrue(session.canDeleteLocally)
        XCTAssertFalse(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: session.id,
            contextID: session.contextID, expectedRevision: session.revision))
        XCTAssertNil(model.composerForwardIntent)
    }

    func testStagingAlbumForwardsOnlySelectedMembers() throws {
        let model = try fixture(members: [81, 83, 84]); model.draft = "source input"
        XCTAssertTrue(try toggle(model))
        let session = try XCTUnwrap(model.messageSelection.session)
        XCTAssertTrue(model.toggleMessageSelection(messageID: "synthetic:10001:83", sessionID: session.id,
            contextID: session.contextID, windowID: try XCTUnwrap(model.historyWindowID)))
        let selected = try XCTUnwrap(model.messageSelection.session)
        XCTAssertTrue(model.stageSelectedMessagesForward(destinationChatID: 10002, sessionID: session.id,
            contextID: session.contextID, expectedRevision: selected.revision))
        XCTAssertEqual(model.composerForwardIntent?.sources.map(\.messageID), [81, 84])
        model.selectedChatID = 10001; XCTAssertEqual(model.draft, "source input")
    }
}
#endif
