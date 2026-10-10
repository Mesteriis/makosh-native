import Foundation
import TelegramCore

enum TelegramRuntime {
    /// TelegramCore requires a shared logger even in a debug build. Register it
    /// before opening accounts, with all output disabled before any engine work.
    static func configureLogging(directory: URL) {
        let logger = Logger(rootPath: directory.path, basePath: directory.appendingPathComponent("disabled-logs").path)
        logger.logToFile = false
        logger.logToConsole = false
        logger.redactSensitiveData = true
        Logger.setSharedLogger(logger)
        registerLoggingFunctions()
    }
}
