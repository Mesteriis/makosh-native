import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarStoreTests: XCTestCase {
    func testOpenCreatesLocalCalendarOnce() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let first = try await store.localAccount()
        let second = try await store.localAccount()
        XCTAssertEqual(first.1.id, second.1.id)
        XCTAssertEqual(first.0.kind, .local)
        XCTAssertEqual(first.1.access, .write)
        XCTAssertEqual(first.1.name, "Личный")
        let accounts = try await store.accounts()
        XCTAssertEqual(accounts.filter { $0.kind == .local }.count, 1)
    }

    func testAccountsCollectionsAndGroupsRoundTrip() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let account = CalendarAccount(
            kind: .caldav, name: "Яндекс", workingHours: CalendarWorkingHours(days: [1: [900...1080]]),
            caldavServer: URL(string: "https://caldav.yandex.ru"), caldavLogin: "me@ya.ru", serverSchedules: false)
        try await store.saveAccount(account)
        let group = CalendarGroup(name: "Все")
        try await store.saveGroup(group)
        let collection = CalendarCollection(
            accountID: account.id, externalID: "/calendars/me/work/", name: "Работа B", groupIDs: [group.id])
        try await store.saveCollection(collection)
        let accounts = try await store.accounts()
        XCTAssertEqual(accounts.first { $0.id == account.id }, account)
        let collections = try await store.collections()
        XCTAssertEqual(collections.first { $0.id == collection.id }, collection)
        let groups = try await store.groups()
        XCTAssertEqual(groups, [group])
    }

    func testRemovingGroupDetachesCollections() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let (account, local) = try await store.localAccount()
        let keep = CalendarGroup(name: "Остаётся"), gone = CalendarGroup(name: "Уходит")
        try await store.saveGroup(keep)
        try await store.saveGroup(gone)
        var updated = local
        updated.groupIDs = [keep.id, gone.id]
        try await store.saveCollection(updated)
        let other = CalendarCollection(accountID: account.id, externalID: "x", name: "Другой", groupIDs: [gone.id])
        try await store.saveCollection(other)
        try await store.removeGroup(id: gone.id)
        let collections = try await store.collections()
        XCTAssertEqual(collections.first { $0.id == local.id }?.groupIDs, [keep.id])
        XCTAssertEqual(collections.first { $0.id == other.id }?.groupIDs, [])
        let groups = try await store.groups()
        XCTAssertEqual(groups.map(\.id), [keep.id])
    }

    func testRemoveAccountKeepsCalendarsHidden() async throws {
        let store = try await calendarStore(try calendarDatabase())
        let account = CalendarAccount(kind: .subscription, name: "Праздники", subscriptionURL: URL(string: "https://x.test/h.ics"))
        try await store.saveAccount(account)
        let collection = CalendarCollection(accountID: account.id, externalID: "feed", name: "Праздники", access: .read)
        try await store.saveCollection(collection)
        try await store.removeAccount(id: account.id)
        let accounts = try await store.accounts()
        XCTAssertEqual(accounts.first { $0.id == account.id }?.state, .disabled)
        let collections = try await store.collections()
        XCTAssertEqual(collections.first { $0.id == collection.id }?.shown, false)
    }

    func testReopenWithMissingKeyFailsClosed() async throws {
        let db = try calendarDatabase()
        let store = try await calendarStore(db)
        _ = try await store.localAccount()
        await store.close()
        let locked = CalendarStore(
            connectionString: db.connectionString, schema: db.schema, keyProvider: { _, _ in throw CalendarFailure.keyUnavailable })
        do {
            try await locked.open()
            XCTFail("a missing key must fail closed")
        } catch let failure as CalendarFailure { XCTAssertEqual(failure, .keyUnavailable) }
        let reopened = try await calendarStore(db)
        let accounts = try await reopened.accounts()
        XCTAssertEqual(accounts.count, 1)
    }

    func testInvalidSchemaRejected() async throws {
        let db = try CalendarTestDatabase()
        let store = CalendarStore(connectionString: db.connectionString, schema: "Bad-Schema", keyProvider: { _, _ in Data(count: 32) })
        do {
            try await store.open()
            XCTFail("invalid schema must be rejected")
        } catch let failure as CalendarFailure { XCTAssertEqual(failure, .invalidSchema) }
    }
}
