import XCTest
@testable import MakoshTelegram

final class TelegramConfigurationTests: XCTestCase {
    func testConfigurationTrimsWhitespaceAndPreservesHashCase() throws {
        let hash = "0123456789abcdef0123456789ABCDEF"
        let configuration = try TelegramAPIConfiguration(id: " 123\n", hash: "\n" + hash + " ")
        XCTAssertEqual(configuration.id, 123)
        XCTAssertEqual(configuration.hash, hash)
    }

    func testRejectsInvalidIDsAndNonASCIIHash() {
        let hash = String(repeating: "a", count: 32)
        for id in ["", "0", "-1", "+1", "2147483648", "1\u{0}", "１２３"] {
            XCTAssertThrowsError(try TelegramAPIConfiguration(id: id, hash: hash))
        }
        for invalid in ["", String(repeating: "a", count: 31), String(repeating: "a", count: 33),
                        String(repeating: "é", count: 16), String(repeating: "g", count: 32),
                        String(repeating: "a", count: 31) + "\u{0}"] {
            XCTAssertThrowsError(try TelegramAPIConfiguration(id: "1", hash: invalid))
        }
    }

    func testInitializationAndInvalidConfigurationRemainDisconnected() async {
        await MainActor.run {
            let model = TelegramModel()
            XCTAssertEqual(model.phase, .configuration)
            XCTAssertFalse(model.isBusy)
            XCTAssertTrue(model.chats.isEmpty)
            XCTAssertTrue(model.messages.isEmpty)
            XCTAssertNil(model.error)
            model.connect(apiID: "0", apiHash: "invalid-synthetic-value")
            XCTAssertEqual(model.phase, .configuration)
            XCTAssertFalse(model.isBusy)
            XCTAssertNotNil(model.error)
            model.draft = "Синтетический черновик"
            XCTAssertFalse(model.sendMessage(model.draft))
            XCTAssertEqual(model.draft, "Синтетический черновик")
            model.disconnect()
            XCTAssertEqual(model.phase, .configuration)
            XCTAssertNil(model.error)
        }
    }
}
