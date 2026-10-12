import XCTest
import Foundation
@testable import MakoshTelegram

#if DEBUG
final class TelegramContactProfileModelTests: XCTestCase {
    @MainActor func testExplicitProfileMapsSelectedSyntheticAccountAndStopsOnChatSwitch() async throws {
        let model = TelegramModel.syntheticPreview()
        XCTAssertEqual(model.contactProfileState, .idle)
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        XCTAssertEqual(model.contactProfileState, .idle)
        model.loadContactProfile()
        guard case let .ready(profile) = model.contactProfileState else { return XCTFail("Expected explicit profile") }
        let context = model.contactProfileContextID
        XCTAssertEqual(profile.accountID, -1); XCTAssertEqual(profile.peerID, model.selectedChatID)
        XCTAssertTrue(model.isCurrentContactProfile(profile, contextID: context))
        model.selectedChatID = model.chats[1].id
        XCTAssertEqual(model.contactProfileState, .idle)
        XCTAssertFalse(model.isCurrentContactProfile(profile, contextID: context))
        model.loadContactProfile()
        guard case let .ready(next) = model.contactProfileState else { return XCTFail("Expected next profile") }
        XCTAssertNotEqual(profile.peerID, next.peerID)
    }

    @MainActor func testLateAndMismatchedCallbacksCannotPublishOrLinkProfile() async throws {
        let model = TelegramModel.syntheticPreview()
        let chatID = try XCTUnwrap(model.chats.first).id
        model.selectedChatID = chatID; model.loadContactProfile()
        guard case let .ready(profile) = model.contactProfileState else { return XCTFail("Expected profile") }
        model.cancelContactProfile()
        let request = UUID(), context = model.contactProfileContextID
        model.contactProfileRequestID = request
        for scope in [(UUID(), context, Int64(-1), chatID), (request, UUID(), -1, chatID),
                      (request, context, -2, chatID), (request, context, -1, chatID + 1)] {
            model.receiveContactProfile(profile, requestID: scope.0, contextID: scope.1, accountID: scope.2, chatID: scope.3)
            XCTAssertEqual(model.contactProfileState, .idle)
        }
        let wrongPeer = TelegramContactProfile(accountID: -1, peerID: chatID + 1, displayName: "Wrong",
            username: nil, phone: nil, isBot: false, observedAt: profile.observedAt)
        model.receiveContactProfile(wrongPeer, requestID: request, contextID: context, accountID: -1, chatID: chatID)
        XCTAssertEqual(model.contactProfileState, .idle)
        model.receiveContactProfile(profile, requestID: request, contextID: context, accountID: -1, chatID: chatID)
        XCTAssertTrue(model.isCurrentContactProfile(profile, contextID: context))
        model.disconnect()
        model.contactProfileRequestID = request
        model.receiveContactProfile(profile, requestID: request, contextID: context, accountID: -1, chatID: chatID)
        XCTAssertEqual(model.contactProfileState, .idle)
        XCTAssertFalse(model.isCurrentContactProfile(profile, contextID: context))
        model.loadContactProfile(); XCTAssertEqual(model.contactProfileState, .idle)
    }

    @MainActor func testUnavailableAndDismissedRequestsRejectLaterData() async throws {
        let model = TelegramModel.syntheticPreview()
        let chat = try XCTUnwrap(model.chats.first)
        model.selectedChatID = chat.id
        let request = UUID(), context = model.contactProfileContextID
        model.contactProfileRequestID = request
        model.receiveContactProfile(nil, requestID: request, contextID: context, accountID: -1, chatID: chat.id)
        guard case .unavailable = model.contactProfileState else { return XCTFail("Expected unavailable") }
        model.loadContactProfile()
        guard case let .ready(profile) = model.contactProfileState else { return XCTFail("Expected retry") }
        model.cancelContactProfile()
        model.receiveContactProfile(profile, requestID: request, contextID: context, accountID: -1, chatID: chat.id)
        XCTAssertEqual(model.contactProfileState, .idle)
        XCTAssertFalse(model.isCurrentContactProfile(profile, contextID: context))
    }
    @MainActor func testReactiveGroupAndChannelUpdatesRetainRequestAndInvalidateOlderSnapshot() throws {
        for kind: TelegramContactProfile.Kind in [.group, .channel, .supergroup, .bot] {
            let model = TelegramModel.syntheticPreview()
            let chatID = try XCTUnwrap(model.chats.first).id
            model.selectedChatID = chatID
            let request = UUID(), context = model.contactProfileContextID
            model.contactProfileRequestID = request
            let first = TelegramContactProfile(accountID: -1, peerID: chatID, displayName: "Initial",
                username: nil, phone: nil, kind: kind, about: "First description", memberCount: nil,
                observedAt: Date(timeIntervalSince1970: 100))
            model.receiveContactProfile(first, requestID: request, contextID: context, accountID: -1, chatID: chatID)
            XCTAssertEqual(model.contactProfileState, .ready(first))
            XCTAssertEqual(model.contactProfileRequestID, request)
            XCTAssertTrue(model.isCurrentContactProfile(first, contextID: context))
            XCTAssertFalse(first.isPerson, "Group/channel/bot profiles must not become human dossier candidates")
            let second = TelegramContactProfile(accountID: -1, peerID: chatID, displayName: "Updated",
                username: "synthetic", phone: nil, kind: kind, about: "Updated description", memberCount: 42,
                isScam: false, isFake: true, observedAt: Date(timeIntervalSince1970: 101))
            model.receiveContactProfile(second, requestID: request, contextID: context, accountID: -1, chatID: chatID)
            XCTAssertEqual(model.contactProfileState, .ready(second))
            XCTAssertEqual(model.contactProfileRequestID, request)
            XCTAssertFalse(model.isCurrentContactProfile(first, contextID: context))
            XCTAssertTrue(model.isCurrentContactProfile(second, contextID: context))
        }
    }

    @MainActor func testInitiallyUnavailableProfileRecoversOnSameRequestButRejectsWrongScope() throws {
        let model = TelegramModel.syntheticPreview()
        let chatID = try XCTUnwrap(model.chats.first).id
        model.selectedChatID = chatID
        let request = UUID(), context = model.contactProfileContextID
        model.contactProfileRequestID = request
        model.receiveContactProfile(nil, requestID: request, contextID: context, accountID: -1, chatID: chatID)
        guard case .unavailable = model.contactProfileState else { return XCTFail("Expected initial missing cache") }
        XCTAssertEqual(model.contactProfileRequestID, request)
        let recovered = TelegramContactProfile(accountID: -1, peerID: chatID, displayName: "Recovered group",
            username: nil, phone: nil, kind: .group, observedAt: Date(timeIntervalSince1970: 102))
        let unavailable = model.contactProfileState
        for scope in [(UUID(), context, Int64(-1), chatID), (request, UUID(), -1, chatID),
                      (request, context, -2, chatID), (request, context, -1, chatID + 1)] {
            model.receiveContactProfile(recovered, requestID: scope.0, contextID: scope.1, accountID: scope.2, chatID: scope.3)
            XCTAssertEqual(model.contactProfileState, unavailable)
        }
        model.receiveContactProfile(recovered, requestID: request, contextID: context, accountID: -1, chatID: chatID)
        XCTAssertEqual(model.contactProfileState, .ready(recovered))
    }

    @MainActor func testDismissAndReloadSameSelectionRejectsOldReactiveCallbacks() throws {
        let model = TelegramModel.syntheticPreview()
        let chatID = try XCTUnwrap(model.chats.first).id
        model.selectedChatID = chatID; model.loadContactProfile()
        let oldRequest = try XCTUnwrap(model.contactProfileRequestID), context = model.contactProfileContextID
        guard case let .ready(oldProfile) = model.contactProfileState else { return XCTFail("Expected synthetic profile") }
        model.cancelContactProfile(); model.loadContactProfile()
        let newRequest = try XCTUnwrap(model.contactProfileRequestID)
        XCTAssertNotEqual(oldRequest, newRequest)
        let current = model.contactProfileState
        model.receiveContactProfile(nil, requestID: oldRequest, contextID: context, accountID: -1, chatID: chatID)
        XCTAssertEqual(model.contactProfileState, current)
        model.receiveContactProfile(oldProfile, requestID: oldRequest, contextID: context, accountID: -1, chatID: chatID)
        XCTAssertEqual(model.contactProfileState, current)
        XCTAssertEqual(model.contactProfileRequestID, newRequest)
    }

}
#endif
