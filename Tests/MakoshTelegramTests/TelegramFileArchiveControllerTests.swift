import XCTest
import Foundation
import CryptoKit
import CPostgres
import MakoshCore
import Postbox
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramFileArchiveControllerTests: XCTestCase {
    // Catches permanently stranding a pre-policy preparation receipt even after
    // its chat is explicitly enabled, or treating its name as a policy bypass.
    func testLegacyPreparationRetryRequiresEnabledChatAndPreservesExactBytes() async throws {
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let config = try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = root.appendingPathComponent("queue")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let key = Data(repeating: 0x59, count: 32)
        let store = try MessageArchiveStore(connectionString: database.connectionString, schema: database.schema) { _, _ in key }
        let vault = try store.fileVault(), objectID = UUID()
        let bytes = Data("LEGACY_PREPARATION_POLICY_QA".utf8), source = root.appendingPathComponent("source")
        try bytes.write(to: source)
        let envelope = try ArchiveFileCapture(file: source, byteCount: Int64(bytes.count))
            .seal(to: queue.appendingPathComponent(objectID.uuidString.lowercased() + ".envelope"), key: vault.key, objectID: objectID)
        try FileManager.default.removeItem(at: source)
        let identity = TelegramPendingUploadDraft.archiveIdentity(accountID: 1,
            chatID: PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(42)).toInt64(), preparationID: UUID())
        let storageID = SHA256.hash(data: Data((config.endpoint + "\u{0}" + config.region + "\u{0}" + config.bucket).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let legacy = ArchiveFileRecord(id: objectID, identity: identity,
            attachment: .init(id: "prepared", kind: "file", name: "synthetic.txt", size: Int64(bytes.count)),
            objectKey: "vaults/\(vault.id.uuidString.lowercased())/files/\(objectID.uuidString.lowercased())",
            storageID: storageID, receipt: envelope)
        let aad = Data("makosh-file-queue-v1|\(vault.id.uuidString)|\(objectID.uuidString)".utf8)
        let sealed = try XCTUnwrap(AES.GCM.seal(JSONEncoder().encode(legacy), using: SymmetricKey(data: vault.key), authenticating: aad).combined)
        let receiptURL = queue.appendingPathComponent(objectID.uuidString.lowercased() + ".receipt")
        try sealed.write(to: receiptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
        let repository = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: config, spoolDirectory: queue, keyProvider: { _, _ in key })
        let controller = TelegramFileArchiveController(factory: { repository })
        controller.retry()
        for _ in 0..<1000 where controller.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(controller.isBusy)
        let disabledObject = try await S3ObjectStore(configuration: config).head(key: legacy.objectKey)
        XCTAssertNil(disabledObject)
        XCTAssertEqual(try Data(contentsOf: receiptURL), sealed)
        try await repository.setConversationFileSavingEnabled(identity: identity, enabled: true)
        controller.retry()
        for _ in 0..<1000 where controller.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(controller.isBusy)
        let records = try await repository.files(identity: identity, attachmentID: "prepared")
        XCTAssertEqual(records.count, 1, "A valid old receipt must resume after its chat is enabled")
        guard let record = records.first else { return }
        XCTAssertNil(record.purpose, "Retry must preserve immutable legacy metadata")
        let restored = root.appendingPathComponent("restored")
        try await repository.export(record, to: restored)
        XCTAssertEqual(try Data(contentsOf: restored), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
    }

    func testChatChoiceSurvivesReopeningAndStaleChatControlCannotChangeAnotherChat() async throws {
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let config = try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: config, spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _, _ in Data(repeating: 0x59, count: 32) })
        let controller = TelegramFileArchiveController(factory: { repository })
        let groupID = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(42)).toInt64()
        controller.policy.select(accountID: 1, chatID: groupID)
        for _ in 0..<1000 where controller.policy.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.policy.enabled, false)
        let oldContext = try XCTUnwrap(controller.policy.context)
        let saved = await controller.policy.setEnabled(true, contextID: oldContext.id)
        XCTAssertTrue(saved)
        controller.policy.select(accountID: 1, chatID: 43)
        for _ in 0..<1000 where controller.policy.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(controller.policy.enabled, true)
        let stale = await controller.policy.setEnabled(false, contextID: oldContext.id)
        XCTAssertFalse(stale, "A menu captured for another chat must not write")
        let reopened = TelegramFileArchiveController(factory: { repository })
        reopened.policy.select(accountID: 1, chatID: groupID)
        for _ in 0..<1000 where reopened.policy.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(reopened.policy.enabled, true, "The explicit group override must survive a new controller")
        reopened.policy.select(accountID: 2, chatID: groupID)
        for _ in 0..<1000 where reopened.policy.isBusy { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(reopened.policy.enabled, false, "The same peer in another account has its own setting")
    }

    func testPersonalFilesAreSavedButGroupsAndChannelsDefaultToNoS3Copy() async throws {
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let config = try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: config, spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _, _ in Data(repeating: 0x59, count: 32) })
        let controller = TelegramFileArchiveController(factory: { repository })
        let source = root.appendingPathComponent("cache"), bytes = Data("synthetic per-chat retention".utf8)
        try bytes.write(to: source)
        let attachment = MessageArchiveAttachment(id: "policy-file", kind: "file", name: "synthetic.txt", size: Int64(bytes.count))
        for (namespace, count) in [(Namespaces.Peer.CloudUser, 1), (Namespaces.Peer.CloudGroup, 0), (Namespaces.Peer.CloudChannel, 0)] {
            let peerID = PeerId(namespace: namespace, id: PeerId.Id._internalFromInt64Value(42)).toInt64()
            let identity = MessageArchiveIdentity(service: "telegram", accountID: "1", conversationID: String(peerID), messageID: "0:1")
            controller.accept(file: source, byteCount: Int64(bytes.count), identity: identity, attachment: attachment)
            for _ in 0..<1000 where controller.isBusy { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(controller.isBusy)
            let records = try await repository.files(identity: identity, attachmentID: attachment.id)
            XCTAssertEqual(records.count, count, "Default must follow the native peer type, not its display name")
        }
    }

    func testPreQueueConfigurationFailureRetainsFrozenFileAndRetryArchivesAfterUnlink() async throws {
        guard let path = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("Explicit synthetic S3 configuration required") }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: path))
        let dsn = try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"])
        let schema = "makosh_test_" + UUID().uuidString.replacingOccurrences(of: "-",with: "").lowercased()
        addTeardownBlock {
            guard let db = dsn.withCString({ PQconnectdb($0) }) else { throw MessageArchiveError.database }
            defer { PQfinish(db) }
            PQsetNoticeProcessor(db,{ _,_ in },nil)
            guard let result = PQexec(db,"DROP SCHEMA \"\(schema)\" CASCADE") else { throw MessageArchiveError.database }
            defer { PQclear(result) }
            guard PQresultStatus(result) == PGRES_COMMAND_OK else { throw MessageArchiveError.database }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false,attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let repository = try ArchiveFileRepository(connectionString: dsn,schema: schema,configuration: configuration,
            spoolDirectory: root.appendingPathComponent("queue"),keyProvider: { _,_ in Data(repeating: 0x59,count: 32) })
        var configurationUnavailable = true
        let controller = TelegramFileArchiveController(factory: {
            if configurationUnavailable { throw S3ObjectStoreError.configuration }; return repository
        })
        let source = root.appendingPathComponent("cache"), bytes = Data("synthetic pre-queue retry after unlink".utf8)
        try bytes.write(to: source)
        let identity = MessageArchiveIdentity(service: "telegram",accountID: "synthetic-old-account",conversationID: "1",messageID: "0:1")
        let attachment = MessageArchiveAttachment(id: "retry-file",kind: "file",name: "retry.txt",size: Int64(bytes.count))
        controller.accept(file: source,byteCount: Int64(bytes.count),identity: identity,attachment: attachment)
        XCTAssertNotNil(controller.error); XCTAssertFalse(controller.isBusy)
        try FileManager.default.removeItem(at: source)
        configurationUnavailable = false
        controller.retry()
        for _ in 0..<1000 {
            if !controller.isBusy { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(controller.isBusy); XCTAssertNil(controller.error)
        let maybeRecord = try await controller.file(identity: identity,attachmentID: attachment.id)
        let record = try XCTUnwrap(maybeRecord)
        let exported = root.appendingPathComponent("restored")
        try await controller.export(record,to: exported)
        XCTAssertEqual(try Data(contentsOf: exported),bytes)
        let otherIdentity = MessageArchiveIdentity(service: "telegram",accountID: "new-account",conversationID: "1",messageID: "0:1")
        let other = try await controller.file(identity: otherIdentity,attachmentID: attachment.id)
        XCTAssertNil(other)
    }
}
