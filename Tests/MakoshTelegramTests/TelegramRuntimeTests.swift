import Foundation
import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramRuntimeTests: XCTestCase {
    func testDisabledNativeShortAndPostboxLogsNeverCreateFiles() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-logging-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        TelegramRuntime.configureLogging(directory: directory)
        Logger.shared.shortLog("MakoshTest", "synthetic short-log probe")
        postboxLog("synthetic storage diagnostic")
        postboxLogSync()
        Logger.shared.sync()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        var evaluated = false
        Logger.shared.shortLog("MakoshTest", { evaluated = true; return "synthetic lazy log" }())
        Logger.shared.sync()
        XCTAssertFalse(evaluated)
        TelegramRuntime.configureLogging(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

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
