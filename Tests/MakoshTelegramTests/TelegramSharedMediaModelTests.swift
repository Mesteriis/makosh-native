import XCTest
import Foundation
@testable import MakoshTelegram

#if DEBUG
@MainActor final class TelegramSharedMediaModelTests: XCTestCase {
    func testProfileMediaHasIndependentSearchAndClosingDropsResourcesAndOldActivation() async throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        model.loadContactProfile()
        guard case let .ready(profile) = model.contactProfileState else { return XCTFail("Expected profile") }
        model.search.messageQuery = "Synthetic"
        let oldCriteria = model.search.criteria
        XCTAssertTrue(model.openSharedMedia(profile, contextID: model.contactProfileContextID))
        guard model.sharedMedia.criteria.media == .photoVideo else { return XCTFail("Profile must open the combined photo/video collection") }
        XCTAssertEqual(model.sharedMedia.criteria.chatID, profile.peerID)
        XCTAssertEqual(model.search.criteria, oldCriteria)
        let ready = expectation(description: "Independent synthetic gallery")
        let sink = model.sharedMedia.$messageStatus.filter { $0 == .ready }.prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5); sink.cancel()
        let oldContext = model.sharedMedia.resultContextID, profileContext = model.contactProfileContextID
        let id = try XCTUnwrap(model.sharedMedia.messages.first?.id)
        model.cancelContactProfile()
        XCTAssertTrue(model.sharedMedia.messages.isEmpty); XCTAssertTrue(model.sharedMedia.mediaSources.isEmpty)
        XCTAssertFalse(model.openSharedMediaMessage(id: id, contextID: oldContext, profileContextID: profileContext))
    }
    func testGalleryHistoryJumpUsesExactResultAndRejectsChangedSelection() async throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id; model.loadContactProfile()
        guard case let .ready(profile) = model.contactProfileState else { return XCTFail("Expected profile") }
        XCTAssertTrue(model.openSharedMedia(profile, contextID: model.contactProfileContextID))
        guard model.sharedMedia.criteria.media == .photoVideo else { return XCTFail("Expected collection") }
        let ready = expectation(description: "Media results")
        let sink = model.sharedMedia.$messageStatus.filter { $0 == .ready }.prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5); sink.cancel()
        let message = try XCTUnwrap(model.sharedMedia.messages.first)
        XCTAssertTrue(model.openSharedMediaMessage(id: message.id, contextID: model.sharedMedia.resultContextID, profileContextID: model.contactProfileContextID))
        XCTAssertEqual(model.historyFocusID, message.id)
        let context = model.contactProfileContextID
        model.selectedChatID = model.chats[1].id
        XCTAssertFalse(model.openSharedMedia(profile, contextID: context))
        XCTAssertTrue(model.sharedMedia.messages.isEmpty)
    }
}
#endif
