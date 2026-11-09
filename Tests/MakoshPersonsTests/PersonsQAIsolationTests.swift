import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class PersonsQAIsolationTests: XCTestCase {
    private let args = ["Makosh", "--persons-synthetic-preview", "--database-config", "/tmp/x/database.json"]

    func testValidateRejectsForeignFlagsAndSchemas() {
        let good = PersonWorkspaceConfiguration(
            connectionString: "host=127.0.0.1 hostaddr=127.0.0.1 dbname=makosh", schema: "qa_persons_abc")
        XCTAssertNoThrow(try PersonsQAIsolation.validate(configuration: good, arguments: args))
        XCTAssertThrowsError(try PersonsQAIsolation.validate(configuration: good, arguments: ["Makosh", "--database-config", "/tmp/x"]))
        XCTAssertThrowsError(try PersonsQAIsolation.validate(configuration: good, arguments: args + ["--calendar-synthetic-preview"]))
        let otherSchema = PersonWorkspaceConfiguration(connectionString: "host=127.0.0.1 hostaddr=127.0.0.1", schema: "makosh")
        XCTAssertThrowsError(try PersonsQAIsolation.validate(configuration: otherSchema, arguments: args))
        let calendarSchema = PersonWorkspaceConfiguration(
            connectionString: "host=127.0.0.1 hostaddr=127.0.0.1", schema: "qa_calendar_abc")
        XCTAssertThrowsError(try PersonsQAIsolation.validate(configuration: calendarSchema, arguments: args))
        let remote = PersonWorkspaceConfiguration(connectionString: "host=db.example.test dbname=makosh", schema: "qa_persons_abc")
        XCTAssertThrowsError(try PersonsQAIsolation.validate(configuration: remote, arguments: args))
        XCTAssertEqual(PersonsQAIsolation.flag, "--persons-synthetic-preview")
        XCTAssertEqual(PersonsQAIsolation.schemaPrefix, "qa_persons_")
    }
}
