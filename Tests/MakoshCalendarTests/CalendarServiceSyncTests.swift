import Foundation
import XCTest
@testable import MakoshCalendar

final class CalendarServiceSyncTests: XCTestCase {
    private let server = URL(string: "https://work-b.test")!

    func testConnectDiscoversCollectionsAndFirstSyncStoresEvents() async throws {
        let work = synthetic("work-b", events: [timed("Созвон B", 10, 11)], schedules: false)
        let h = try await calendarHarness(["Работа B": work])
        let account = try await h.service.addCalDAVAccount(name: "Работа B", server: server, login: "me@ya.test", password: "app-pass")
        XCTAssertEqual(account.serverSchedules, false)
        XCTAssertEqual(account.state, .connected)
        let collections = try await h.store.collections().filter { $0.accountID == account.id }
        XCTAssertEqual(collections.map(\.externalID), ["work-b"])
        let events = try await h.store.events(collectionIDs: Set(collections.map(\.id)), from: h.at(0), to: h.at(24), includeCopies: true)
        XCTAssertEqual(events.map(\.title), ["Созвон B"])
    }

    func testFailedVerificationStoresNothing() async throws {
        let work = synthetic("work-b")
        await work.failReads(.rejected(code: 401, stage: "calendars"))
        let h = try await calendarHarness(["Работа B": work])
        do {
            _ = try await h.service.addCalDAVAccount(name: "Работа B", server: server, login: "me@ya.test", password: "wrong")
            XCTFail("a refused login must not create an account")
        } catch {}
        let accounts = try await h.store.accounts()
        XCTAssertFalse(accounts.contains { $0.kind == .caldav })
    }

    func testIncrementalSyncAppliesRemovalsKeepingHistory() async throws {
        let work = synthetic("work-b", events: [timed("Созвон B", 10, 11)])
        let h = try await calendarHarness(["Работа B": work])
        let account = try await h.service.addCalDAVAccount(name: "Работа B", server: server, login: "me", password: "p")
        let collection = try await h.store.collections().first { $0.accountID == account.id }!
        let stored = try await h.store.events(collectionIDs: [collection.id], from: h.at(0), to: h.at(24), includeCopies: true)
        let id = try XCTUnwrap(stored.first?.externalID)
        await work.remove(externalID: id, collectionExternalID: "work-b")
        await h.service.sync(accountID: account.id)
        let event = try await h.store.event(externalID: id, collectionID: collection.id)
        XCTAssertNotNil(event?.deletedAt)
        let versions = try await h.store.versions(eventID: event!.id)
        XCTAssertEqual(versions.count, 2)
    }

    func testFullResyncKeepsTaskLinks() async throws {
        let work = synthetic("work-b", events: [timed("Созвон B", 10, 11)])
        let h = try await calendarHarness(["Работа B": work])
        let account = try await h.service.addCalDAVAccount(name: "Работа B", server: server, login: "me", password: "p")
        let collection = try await h.store.collections().first { $0.accountID == account.id }!
        var event = try await h.store.events(collectionIDs: [collection.id], from: h.at(0), to: h.at(24), includeCopies: true)[0]
        let task = UUID()
        event.taskID = task
        _ = try await h.store.update(event, expectedRevision: event.revision, actor: .user)
        try await h.store.saveCursor(nil, collectionID: collection.id)
        await h.service.sync(accountID: account.id)
        let after = try await h.store.event(id: event.id)
        XCTAssertEqual(after?.taskID, task)
        XCTAssertNil(after?.deletedAt)
    }

    func testRevokedGrantMarksNeedsSignInAndStale() async throws {
        let work = synthetic("work-b")
        let h = try await calendarHarness(["Работа B": work])
        let account = try await h.service.addCalDAVAccount(name: "Работа B", server: server, login: "me", password: "p")
        await work.failReads(.signInRequired)
        await h.service.sync(accountID: account.id)
        let snapshot = try await h.service.snapshot(window: DateInterval(start: h.at(0), duration: 86400))
        XCTAssertEqual(snapshot.accounts.first { $0.id == account.id }?.state, .needsSignIn)
        let collection = snapshot.collections.first { $0.accountID == account.id }!
        XCTAssertTrue(snapshot.staleCollectionIDs.contains(collection.id))
        await work.failReads(.rejected(code: 401, stage: "events"))
        await h.service.sync(accountID: account.id)
        let again = try await h.store.accounts().first { $0.id == account.id }
        XCTAssertEqual(again?.state, .needsSignIn)
    }

    func testAdminBlockedStateIsDistinct() async throws {
        let work = synthetic("work-b")
        let h = try await calendarHarness(["Работа B": work])
        let account = try await h.service.addCalDAVAccount(name: "Работа B", server: server, login: "me", password: "p")
        await work.failReads(.adminBlocked)
        await h.service.sync(accountID: account.id)
        let state = try await h.store.accounts().first { $0.id == account.id }?.state
        XCTAssertEqual(state, .adminBlocked)
    }

    func testSubscriptionPolledHourly() async throws {
        let feed = synthetic("holidays", access: .read)
        let work = synthetic("work-b")
        let h = try await calendarHarness(["Праздники": feed, "Работа B": work])
        _ = try await h.service.addSubscription(name: "Праздники", url: URL(string: "https://feeds.test/h.ics")!)
        _ = try await h.service.addCalDAVAccount(name: "Работа B", server: server, login: "me", password: "p")
        let baseFeed = await feed.reads, baseWork = await work.reads
        await h.service.syncDue()
        let r1 = await feed.reads
        XCTAssertEqual(r1, baseFeed, "just synced on connect")
        h.clock.set(h.at(0.06))  // ~3.6 minutes
        await h.service.syncDue()
        let r2 = await work.reads
        XCTAssertEqual(r2, baseWork + 1)
        let r3 = await feed.reads
        XCTAssertEqual(r3, baseFeed)
        h.clock.set(h.at(1.1))
        await h.service.syncDue()
        let r4 = await feed.reads
        XCTAssertEqual(r4, baseFeed + 1)
    }

    func testSnapshotExpandsOccurrencesInWindow() async throws {
        var series = timed("Планёрка", 9, 9.5)
        series.recurrence = CalendarRecurrence(rrule: "FREQ=DAILY")
        let work = synthetic("work-b", events: [series])
        let h = try await calendarHarness(["Работа B": work])
        _ = try await h.service.addCalDAVAccount(name: "Работа B", server: server, login: "me", password: "p")
        let snapshot = try await h.service.snapshot(window: DateInterval(start: h.at(0), duration: 7 * 86400))
        XCTAssertEqual(snapshot.occurrences.filter { snapshot.events[$0.eventID]?.title == "Планёрка" }.count, 7)
        XCTAssertFalse(snapshot.googleAvailable)
    }

    func testLocalAccountExistsAfterOpen() async throws {
        let h = try await calendarHarness([:])
        let snapshot = try await h.service.snapshot(window: DateInterval(start: h.at(0), duration: 86400))
        XCTAssertEqual(snapshot.accounts.map(\.kind), [.local])
        XCTAssertEqual(snapshot.collections.map(\.name), ["Личный"])
    }
}
