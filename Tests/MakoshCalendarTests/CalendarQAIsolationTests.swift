import Foundation
import MakoshCore
import XCTest
@testable import MakoshCalendar

final class CalendarQAIsolationTests: XCTestCase {
    private let args = ["Makosh", "--calendar-synthetic-preview", "--database-config", "/tmp/x/database.json"]

    func testIsolationRequiresFlagLoopbackAndPrefix() {
        let good = PersonWorkspaceConfiguration(
            connectionString: "host=127.0.0.1 hostaddr=127.0.0.1 dbname=makosh", schema: "qa_calendar_abc")
        XCTAssertNoThrow(try CalendarQAIsolation.validate(configuration: good, arguments: args))
        XCTAssertThrowsError(try CalendarQAIsolation.validate(configuration: good, arguments: ["Makosh", "--database-config", "/tmp/x"]))
        XCTAssertThrowsError(try CalendarQAIsolation.validate(configuration: good, arguments: args + ["--tasks-synthetic-preview"]))
        let otherSchema = PersonWorkspaceConfiguration(connectionString: "host=127.0.0.1 hostaddr=127.0.0.1", schema: "makosh")
        XCTAssertThrowsError(try CalendarQAIsolation.validate(configuration: otherSchema, arguments: args))
        let remote = PersonWorkspaceConfiguration(connectionString: "host=db.example.test dbname=makosh", schema: "qa_calendar_abc")
        XCTAssertThrowsError(try CalendarQAIsolation.validate(configuration: remote, arguments: args))
        XCTAssertEqual(CalendarQAIsolation.flag, "--calendar-synthetic-preview")
    }
}
