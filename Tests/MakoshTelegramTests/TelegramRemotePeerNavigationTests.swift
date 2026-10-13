#if DEBUG
import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramRemotePeerNavigationTests: XCTestCase {
    private enum WaitError: Error { case timeout }
    private func ready(_ model: TelegramModel) async throws {
        let clock = ContinuousClock(); let end = clock.now.advanced(by: .seconds(2))
        while model.search.discovery.status != .ready { guard clock.now < end else { XCTFail("Discovery did not complete"); throw WaitError.timeout }; try await Task.sleep(for: .milliseconds(20)) }
    }
    func testRemoteConversationOpensWithFreshResultAndPreservesOriginDraft() async throws {
        let model = TelegramModel.syntheticPreview(); let origin = try XCTUnwrap(model.chats.first).id
        model.selectedChatID = origin; model.draft = "Synthetic preserved origin"
        model.search.chatQuery = "@alice_external"; try await ready(model)
        let context = model.search.discovery.contextID
        XCTAssertEqual(model.search.discovery.results.map(\.id),[970001])
        XCTAssertTrue(model.openDiscoveredPeer(id:970001,contextID:context))
        XCTAssertEqual(model.selectedChat?.title,"Synthetic Remote Alice")
        XCTAssertEqual(model.selectedChatID,970001)
        model.selectedChatID = origin
        XCTAssertEqual(model.draft,"Synthetic preserved origin")
    }
    func testOldResultCannotOpenAfterDisconnectAndArchiveDoesNotDiscover() async throws {
        let model = TelegramModel.syntheticPreview(); model.search.chatQuery = "alice_external"; try await ready(model)
        let context = model.search.discovery.contextID
        model.disconnect()
        XCTAssertFalse(model.openDiscoveredPeer(id:970001,contextID:context))
        XCTAssertEqual(model.search.discovery.status,.idle)
        let archive = TelegramModel.syntheticPreview(); archive.chatFolder = .archive; archive.search.chatQuery = "alice_external"
        try await Task.sleep(for:.milliseconds(400))
        XCTAssertEqual(archive.search.discovery.status,.idle); XCTAssertTrue(archive.search.discovery.results.isEmpty)
    }
}
#endif
