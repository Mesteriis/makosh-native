import Foundation
import XCTest
import TelegramCore
@testable import MakoshTelegram

final class TelegramRuntimeTests: XCTestCase {
    func testRequiredEngineLoggerIsRegisteredWithNoOutputOrFilesystemCreation() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        TelegramRuntime.configureLogging(directory: directory)
        XCTAssertFalse(Logger.shared.logToFile)
        XCTAssertFalse(Logger.shared.logToConsole)
        XCTAssertTrue(Logger.shared.redactSensitiveData)
        Logger.shared.log("MakoshTest", "synthetic test data")
        Logger.shared.sync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
