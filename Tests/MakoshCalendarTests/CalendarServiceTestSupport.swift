import Foundation
import XCTest
@testable import MakoshCalendar

/// A service on a real PostgreSQL schema with synthetic servers chosen by account name.
struct CalendarServiceHarness {
    let db: CalendarTestDatabase
    let store: CalendarStore
    let service: CalendarService
    let clock: LockedBox<Date>
    let adapters: [String: CalendarSyntheticAdapter]

    static let start = Date(timeIntervalSince1970: 1_794_096_000)  // 2026-11-08 00:00Z
    func at(_ hours: Double) -> Date { Self.start.addingTimeInterval(hours * 3600) }
}

extension XCTestCase {
    nonisolated(nonsending) func calendarHarness(_ adapters: [String: CalendarSyntheticAdapter]) async throws -> CalendarServiceHarness {
        try await calendarHarness(adapters: adapters.mapValues { $0 as any CalendarAdapter }, synthetic: adapters)
    }

    /// Any adapter per account name; `synthetic` names the ones tests drive directly.
    nonisolated(nonsending) func calendarHarness(
        adapters: [String: any CalendarAdapter], synthetic: [String: CalendarSyntheticAdapter] = [:]
    ) async throws -> CalendarServiceHarness {
        let db = try calendarDatabase()
        let clock = LockedBox(CalendarServiceHarness.start)
        let store = try await calendarStore(db, now: { clock.get() })
        let service = CalendarService(
            store: store, vault: CalendarCredentialVault(access: .memory()),
            adapterFactory: { account, _ in
                guard let adapter = adapters[account.name] else { throw CalendarFailure.notFound }
                return adapter
            }, google: nil, now: { clock.get() })
        try await service.open()
        return CalendarServiceHarness(db: db, store: store, service: service, clock: clock, adapters: synthetic)
    }

    func synthetic(
        _ externalID: String, access: CalendarAccess = .write, events: [CalendarEvent] = [], schedules: Bool = true
    )
        -> CalendarSyntheticAdapter
    {
        CalendarSyntheticAdapter(
            collections: [RemoteCollection(externalID: externalID, name: externalID, color: nil, access: access)],
            events: [externalID: events],
            schedules: schedules)
    }

    func timed(_ title: String, _ from: Double, _ to: Double, uid: String = UUID().uuidString) -> CalendarEvent {
        CalendarEvent(
            collectionID: UUID(), uid: uid, title: title,
            time: .timed(
                start: CalendarServiceHarness.start.addingTimeInterval(from * 3600),
                end: CalendarServiceHarness.start.addingTimeInterval(to * 3600), timeZone: nil))
    }
}

/// A tiny lock-protected box for values crossing test closures.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ value: Value) { lock.withLock { self.value = value } }
}
