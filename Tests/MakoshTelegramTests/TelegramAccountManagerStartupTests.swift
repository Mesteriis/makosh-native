import Foundation
import XCTest
import TelegramCore
import SwiftSignalKit
@testable import MakoshTelegram

final class TelegramAccountManagerStartupTests: XCTestCase {
    nonisolated private static func recordCount(_ transaction: AccountManagerModifier<TelegramAccountManagerTypes>) -> Int {
        transaction.getRecords().count
    }

    @MainActor func testFreshMetadataOpensWithoutDestructiveRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-account-start-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        TelegramRuntime.configureLogging(directory: root)
        initializeAccountManagement()
        let metadata = root.appendingPathComponent("accounts-metadata")
        let manager = AccountManager<TelegramAccountManagerTypes>(basePath: metadata.path,
            isTemporary: false, isReadOnly: false, useCaches: true, removeDatabaseOnError: false)
        let count = try await telegramDataValue(manager.transaction(Self.recordCount), test: self)
        try await warmMediaStorage(manager)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.appendingPathComponent("atomic-state").path))
    }

    @MainActor func testSafeOpenCreatesStateAndReopensStoredRecords() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("accounts-metadata")
        let first = try await open(metadata)
        var manager = try XCTUnwrap(first)
        let id = try await telegramDataValue(manager.transaction(Self.createRecord), test: self)
        let bytes = try Data(contentsOf: metadata.appendingPathComponent("atomic-state"))
        let reopened = try await open(metadata)
        manager = try XCTUnwrap(reopened)
        let records = try await telegramDataValue(manager.transaction(Self.recordIDs), test: self)
        XCTAssertEqual(records, [id])
        XCTAssertEqual(try Data(contentsOf: metadata.appendingPathComponent("atomic-state")), bytes)
    }

    @MainActor func testCorruptStateIsRefusedWithoutRemoval() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("accounts-metadata")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        let bytes = Data("synthetic invalid state".utf8)
        let state = metadata.appendingPathComponent("atomic-state")
        try bytes.write(to: state)
        let manager = try await open(metadata)
        XCTAssertNil(manager)
        XCTAssertEqual(try Data(contentsOf: state), bytes)
    }

    @MainActor func testInterruptedEmptyFirstOpenCanRetry() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("accounts-metadata")
        var manager = try await open(metadata)
        XCTAssertNotNil(manager)
        _ = try await telegramDataValue(try XCTUnwrap(manager).transaction(Self.recordCount), test: self)
        manager = nil
        try FileManager.default.removeItem(at: metadata.appendingPathComponent("atomic-state"))
        let retried = try await open(metadata)
        let count = try await telegramDataValue(try XCTUnwrap(retried).transaction(Self.recordCount), test: self)
        XCTAssertEqual(count, 0)
    }

    @MainActor func testPendingAuthorizationRecordSurvivesReopen() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("accounts-metadata")
        let first = try await open(metadata)
        let account = try await telegramDataValue(try XCTUnwrap(first).currentAccountRecord(allocateIfNotExists: true), test: self)
        let expectedID = try XCTUnwrap(account).0
        let second = try await open(metadata)
        let reopened = try await telegramDataValue(try XCTUnwrap(second).currentAccountRecord(allocateIfNotExists: false), test: self)
        XCTAssertEqual(try XCTUnwrap(reopened).0, expectedID)
    }

    @MainActor func testMissingStateWithExistingAccountCacheIsRefused() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("account-123")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
        let sentinel = cache.appendingPathComponent("synthetic-cache")
        let bytes = Data("preserve existing account cache".utf8)
        try bytes.write(to: sentinel)
        let metadata = root.appendingPathComponent("accounts-metadata")
        let manager = try await open(metadata)
        XCTAssertNil(manager)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.appendingPathComponent("atomic-state").path))
        XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
    }

    @MainActor func testBlockedDatabasePathReturnsFailureAndPreservesFile() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadata = root.appendingPathComponent("accounts-metadata")
        let bytes = Data("synthetic path obstruction".utf8)
        try bytes.write(to: metadata)
        let manager = try await open(metadata)
        XCTAssertNil(manager)
        XCTAssertEqual(try Data(contentsOf: metadata), bytes)
    }

    @MainActor private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-account-start-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        TelegramRuntime.configureLogging(directory: root)
        initializeAccountManagement()
        return root
    }

    @MainActor private func open(_ metadata: URL) async throws -> AccountManager<TelegramAccountManagerTypes>? {
        let manager = try await telegramDataValue(AccountManager<TelegramAccountManagerTypes>.makoshOpen(basePath: metadata.path), test: self)
        if let manager { try await warmMediaStorage(manager) }
        return manager
    }

    @MainActor private func warmMediaStorage(_ manager: AccountManager<TelegramAccountManagerTypes>) async throws {
        // Native MediaBox initializes asynchronously. Finish owned work before
        // deleting a disposable fixture directory, like the Postbox fixtures.
        _ = try await telegramDataValue(manager.mediaBox.storageBox.all(), test: self)
        _ = try await telegramDataValue(manager.mediaBox.cacheStorageBox.all(), test: self)
    }

    nonisolated private static func createRecord(_ transaction: AccountManagerModifier<TelegramAccountManagerTypes>) -> AccountRecordId {
        transaction.createRecord([])
    }

    nonisolated private static func recordIDs(_ transaction: AccountManagerModifier<TelegramAccountManagerTypes>) -> [AccountRecordId] {
        transaction.getRecords().map(\.id)
    }
}
