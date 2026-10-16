import XCTest
@testable import MakoshTelemost

@MainActor final class TelemostHiddenMeetingsTests: XCTestCase {
    func testHiddenRecordsRemainAvailableAcrossPagingAndRestartForExplicitRecovery() async throws {
        let db = try TelemostTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repo = TelemostRepository(keyProvider: telemostTestKey); try await repo.open(configuration: db.configuration)
        let hidden = TelemostLocalMeeting(accountID: nil, validatedURL: try .init("https://telemost.yandex.ru/j/hidden"), localTitle: "unique-hidden", hidden: true)
        try await repo.saveLocal(hidden)
        for index in 0..<60 { try await repo.saveLocal(.init(accountID: nil, validatedURL: try .init("https://telemost.yandex.ru/j/page-\(index)"))) }
        let first = try await repo.page(accountID: nil, query: "", before: nil, limit: 50)
        let second = try await repo.page(accountID: nil, query: "", before: first.next, limit: 50)
        XCTAssertEqual(first.values.count + second.values.count, 61)
        XCTAssertTrue(second.values.contains { $0.id == hidden.id && $0.hidden })
        await repo.close()
        let reopened = TelemostRepository(keyProvider: telemostTestKey); try await reopened.open(configuration: db.configuration)
        let page = try await reopened.page(accountID: nil, query: "unique-hidden", before: nil, limit: 50)
        XCTAssertEqual(page.values.count, 1)
        if var value = page.values.first { value.hidden = false; try await reopened.saveLocal(value)
            let visible = try await reopened.page(accountID: nil, query: "unique-hidden", before: nil, limit: 50); XCTAssertEqual(visible.values.first?.hidden, false)
        }
        await reopened.close()
    }
}
