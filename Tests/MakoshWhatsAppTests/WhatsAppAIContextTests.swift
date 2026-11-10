import Foundation
import MakoshAI
import MakoshCore
import XCTest
@testable import MakoshApp
@testable import MakoshWhatsApp

final class WhatsAppAIContextTests: XCTestCase {
    private func message(_ id: String, text: String, protected: Bool? = nil) -> WhatsAppMessage {
        var message = WhatsAppMessage(
            chat: "1@s.whatsapp.net", id: id, stanza: id, sender: "1@s.whatsapp.net", timestamp: 10, outgoing: false, text: text,
            kind: "text",
            edited: false, deleted: false)
        if let protected {
            var details = WhatsAppMessageDetails()
            details.protected = protected
            message.details = details
        }
        return message
    }

    /// A view-once message stays off the AI card and is counted as hidden, as
    /// Telegram's copy-protected messages are; notifications and file actions
    /// already honour the same flag.
    func testProtectedMessageIsHiddenFromTheAICard() throws {
        let account = UUID().uuidString
        let candidates = [
            message("m1", text: "только раз", protected: true), message("m2", text: "привет"),
            message("m3", text: "без защиты", protected: false),
        ].map { AIContextBridge.whatsappCandidate($0, accountID: account) }
        let result = try AIContextAccess.apply(
            candidates, privatePeer: nil, snapshot: AIAccessSnapshot(enabledScopes: [], contactAccess: [:]))
        XCTAssertEqual(result.lines.map(\.text), ["привет", "без защиты"])
        XCTAssertEqual(result.hiddenProtected, 1)
    }
}
