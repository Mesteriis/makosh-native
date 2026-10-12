import XCTest
@testable import MakoshTelegram

#if DEBUG
@MainActor final class TelegramMessageDeliveryModelTests: XCTestCase {
    private func replacingDelivery(_ original: TelegramMessage, with delivery: TelegramMessageDelivery) -> TelegramMessage {
        var result = TelegramMessage(id: original.id, date: original.date, text: original.text,
            author: original.author, isOutgoing: original.isOutgoing, delivery: delivery)
        result.attachments = original.attachments
        result.actionMetadata = original.actionMetadata
        return result
    }
    func testDeliveryOnlyEmissionUpdatesCurrentWindowAndRejectsPreviousWindow() throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        let window = try XCTUnwrap(model.historyWindowID)
        let original = try XCTUnwrap(model.messages.first(where: \.isOutgoing))
        let sent = replacingDelivery(original, with: .sent)
        let read = replacingDelivery(original, with: .read)
        model.receiveMessages([sent], requestID: window, previous: nil, next: nil, isLoading: false)
        XCTAssertEqual(model.messages, [sent])
        model.receiveMessages([read], requestID: window, previous: nil, next: nil, isLoading: false)
        XCTAssertEqual(model.messages, [read])
        XCTAssertEqual(model.messages.first?.text, original.text)
        let chat = model.selectedChatID
        model.selectedChatID = nil
        model.selectedChatID = chat
        let current = try XCTUnwrap(model.historyWindowID)
        XCTAssertNotEqual(window, current)
        let currentMessages = model.messages
        model.receiveMessages([sent], requestID: window, previous: nil, next: nil, isLoading: false)
        XCTAssertEqual(model.messages, currentMessages)
    }
    func testChatSwitchAndAccountResetRejectOldDeliveryEmission() throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        let oldWindow = try XCTUnwrap(model.historyWindowID)
        let oldMessage = try XCTUnwrap(model.messages.first(where: \.isOutgoing))
        let read = replacingDelivery(oldMessage, with: .read)
        model.selectedChatID = try XCTUnwrap(model.chats.first { $0.id != model.selectedChatID }).id
        let current = model.messages
        model.receiveMessages([read], requestID: oldWindow, previous: nil, next: nil, isLoading: false)
        XCTAssertEqual(model.messages, current)
        let currentWindow = try XCTUnwrap(model.historyWindowID)
        model.disconnect()
        model.receiveMessages([read], requestID: currentWindow, previous: nil, next: nil, isLoading: false)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.historyWindowID)
        XCTAssertEqual(model.phase, .configuration)
    }
}
#endif
