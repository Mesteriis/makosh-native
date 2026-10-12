import XCTest
import Foundation
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func quoteAccountSetLimit(_ box: Postbox, limit: Double?) -> Signal<Void, NoError> {
    box.transaction { transaction in
        var config = AppConfiguration.defaultValue
        config.data = .dictionary(limit.map { ["quote_length_max": .number($0)] } ?? [:])
        transaction.updatePreferencesEntry(key: PreferencesKeys.appConfiguration) { _ in PreferencesEntry(config) }
    }
}
@MainActor final class TelegramReplyQuoteAccountTests: TelegramSourceFactsIntegrationTestCase {
    func testCurrentAccountQuoteLimitIsObservedAcrossPreferenceUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let box = try await sourceFactsOpen(root.appendingPathComponent("postbox"))
        _ = try await sourceFactsValue(quoteAccountSetLimit(box, limit: 2048))
        let first = expectation(description: "Initial quote limit"), next = expectation(description: "Changed quote limit")
        var values: [Int] = []
        let lease = (telegramReplyQuoteLimitSignal(postbox: box) |> deliverOnMainQueue).start(next: { value in
            values.append(value)
            if values.count == 1 { first.fulfill() }
            if values.count == 2 { next.fulfill() }
        })
        defer { lease.dispose() }
        await fulfillment(of: [first], timeout: 3)
        XCTAssertEqual(values, [2048])
        _ = try await sourceFactsValue(quoteAccountSetLimit(box, limit: 512))
        await fulfillment(of: [next], timeout: 3)
        XCTAssertEqual(values, [2048, 512])
        let source = try TelegramFormattedText(text: String(repeating: "x", count: 513))
        XCTAssertNil(TelegramReplyQuote(source: source, selection: .init(location: 0, length: 513), maximumLength: values.last ?? 0))
    }
}
