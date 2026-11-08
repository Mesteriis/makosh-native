import Foundation
import XCTest
@testable import MakoshCalendar

final class SubscriptionAdapterTests: XCTestCase {
    private let window = DateInterval(start: Date(timeIntervalSince1970: 1_794_096_000), duration: 90 * 86400)
    private func feed(_ uids: [String]) -> Data {
        Data(
            ICSFixture.wrap(uids.map { "BEGIN:VEVENT\nUID:\($0)\nDTSTART;VALUE=DATE:20261231\nSUMMARY:\($0)\nEND:VEVENT\n" }.joined()).utf8)
    }

    func testWebcalBecomesHTTPS() async throws {
        let adapter = try SubscriptionAdapter(url: URL(string: "webcal://feeds.test/holidays.ics")!, http: StubURLProtocol.http())
        let collections = try await adapter.collections()
        XCTAssertEqual(collections.map(\.externalID), ["https://feeds.test/holidays.ics"])
        XCTAssertEqual(collections.map(\.access), [.read])
        XCTAssertThrowsError(try SubscriptionAdapter(url: URL(string: "http://feeds.test/x.ics")!, http: StubURLProtocol.http()))
        XCTAssertThrowsError(try SubscriptionAdapter(url: URL(string: "file:///etc/hosts")!, http: StubURLProtocol.http()))
    }

    func testNotModifiedYieldsNoChanges() async throws {
        StubURLProtocol.install { _ in .init(status: 200, headers: ["ETag": "\"v1\""], body: self.feed(["a"])) }
        let adapter = try SubscriptionAdapter(url: URL(string: "https://feeds.test/h.ics")!, http: StubURLProtocol.http())
        let collection = CalendarCollection(accountID: UUID(), externalID: "https://feeds.test/h.ics", name: "Праздники", access: .read)
        let first = try await adapter.changes(collection: collection, cursor: nil, window: window)
        XCTAssertEqual(first.events.map(\.uid), ["a"])
        XCTAssertTrue(first.full)
        StubURLProtocol.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
            return .init(status: 304)
        }
        let second = try await adapter.changes(collection: collection, cursor: first.cursor, window: window)
        XCTAssertTrue(second.events.isEmpty && second.removedExternalIDs.isEmpty)
        XCTAssertFalse(second.full)
        XCTAssertEqual(second.cursor, first.cursor)
    }

    func testMissingUIDsBecomeRemovals() async throws {
        StubURLProtocol.install { _ in .init(status: 200, body: self.feed(["a", "b"])) }
        let adapter = try SubscriptionAdapter(url: URL(string: "https://feeds.test/h.ics")!, http: StubURLProtocol.http())
        let collection = CalendarCollection(accountID: UUID(), externalID: "https://feeds.test/h.ics", name: "Праздники", access: .read)
        let first = try await adapter.changes(collection: collection, cursor: nil, window: window)
        StubURLProtocol.install { _ in .init(status: 200, body: self.feed(["b"])) }
        let second = try await adapter.changes(collection: collection, cursor: first.cursor, window: window)
        XCTAssertEqual(second.events.map(\.externalID), ["b"])
        XCTAssertEqual(second.removedExternalIDs, ["a"])
    }

    func testSubscriptionIsReadOnly() async throws {
        let adapter = try SubscriptionAdapter(url: URL(string: "https://feeds.test/h.ics")!, http: StubURLProtocol.http())
        let collection = CalendarCollection(accountID: UUID(), externalID: "https://feeds.test/h.ics", name: "Праздники", access: .read)
        do {
            _ = try await adapter.create(CalendarEvent.fixture(start: 1, end: 2), in: collection, notify: false)
            XCTFail("a subscription must refuse writes")
        } catch { XCTAssertEqual(error as? CalendarFailure, .invalidInput("read only")) }
    }
}
