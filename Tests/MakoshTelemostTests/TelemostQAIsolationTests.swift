import XCTest
@testable import MakoshCore
@testable import MakoshApp
@testable import MakoshTelemost

final class TelemostQAIsolationTests: XCTestCase {
    let args = ["Makosh", "--telemost-synthetic-preview", "--database-config", "/owned/database.json", "--telemost-qa-exports", "/owned/exports"]
    func config(_ host: String = "host=127.0.0.1 hostaddr=127.0.0.1 user=synthetic dbname=qa", _ schema: String = "qa_telemost_app", _ archive: String? = "qa_telemost_archive") -> ContactWorkspaceConfiguration { .init(connectionString: host, schema: schema, archiveSchema: archive) }
    func testBothSchemaPrefixesAndExplicitArgumentsRequired() {
        XCTAssertNoThrow(try TelemostQAIsolation.validate(configuration: config(), arguments: args))
        for value in [config("host=127.0.0.1 hostaddr=127.0.0.1", "makosh"), config("host=127.0.0.1 hostaddr=127.0.0.1", "qa_telemost_app", "makosh_archive"), config("host=127.0.0.1 hostaddr=127.0.0.1", "qa_telemost_app", nil)] { XCTAssertThrowsError(try TelemostQAIsolation.validate(configuration: value, arguments: args)) }
        for invalid in [[], ["--telemost-synthetic-preview"], args + ["--teams-synthetic-preview"], args + ["--telemost-api-url", "https://example.invalid"]] { XCTAssertThrowsError(try TelemostQAIsolation.validate(configuration: config(), arguments: invalid)) }
    }
    func testPinnedLoopbackAndNoRealBoundaries() {
        for host in ["host=localhost dbname=qa", "host=127.0.0.1 hostaddr=203.0.113.1", "host=127.0.0.1,example.invalid hostaddr=127.0.0.1", "host=example.invalid hostaddr=127.0.0.1", "host=127.0.0.1 hostaddr=127.0.0.1 service=personal", "host=127.0.0.1 hostaddr=127.0.0.1 options='-c search_path=makosh'"] { XCTAssertThrowsError(try TelemostQAIsolation.validate(configuration: config(host), arguments: args)) }
        XCTAssertFalse(TelemostSyntheticLaunchPolicy.admits(arguments: [], configuration: config()))
    }
    func testMarkedBundleFailsClosedBeforeIO() {
        XCTAssertFalse(TelemostSyntheticLaunchPolicy.permitsNormalLaunch(marker: "telemost", arguments: []))
        XCTAssertFalse(TelemostSyntheticLaunchPolicy.permitsNormalLaunch(marker: nil, arguments: args))
        XCTAssertTrue(TelemostSyntheticLaunchPolicy.permitsNormalLaunch(marker: nil, arguments: []))
    }
}
