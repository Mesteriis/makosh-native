import XCTest
import Foundation
import CryptoKit
@testable import MakoshCore

final class ConversationFilePolicyTests: XCTestCase {
    private let key = Data(repeating: 0x64, count: 32)
    private let identity = MessageArchiveIdentity(service: "telegram", accountID: "synthetic-account",
        conversationID: "synthetic-chat", messageID: "0:1")
    private let attachment = MessageArchiveAttachment(id: "policy-file", kind: "file",
        name: "synthetic-policy.txt", size: nil)

    private func database() throws -> PostgresTestDatabase {
        let db = try PostgresTestDatabase()
        addTeardownBlock { try db.cleanup() }
        return db
    }
    private func store(_ db: PostgresTestDatabase) throws -> MessageArchiveStore {
        let key = key
        return try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { _, _ in key }
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func config() throws -> S3ObjectStoreConfiguration {
        guard let path = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else {
            throw XCTSkip("S3 integration requires explicit synthetic development configuration")
        }
        return try S3ConfigurationFile.read(URL(fileURLWithPath: path))
    }
    private func repository(_ db: PostgresTestDatabase, _ root: URL,
                            _ config: S3ObjectStoreConfiguration) throws -> ArchiveFileRepository {
        let key = key
        return try ArchiveFileRepository(connectionString: db.connectionString, schema: db.schema,
            configuration: config, spoolDirectory: root.appendingPathComponent("queue"),
            keyProvider: { _, _ in key })
    }
    private func capture(_ root: URL) throws -> ArchiveFileCapture {
        let bytes = Data("SYNTHETIC_CONVERSATION_FILE_POLICY".utf8)
        let source = root.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        return try ArchiveFileCapture(file: source, byteCount: Int64(bytes.count))
    }
    private func queueFiles(_ root: URL) throws -> [URL] {
        let queue = root.appendingPathComponent("queue")
        guard FileManager.default.fileExists(atPath: queue.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: queue, includingPropertiesForKeys: nil)
    }
    private func failedQueueRepository(_ db: PostgresTestDatabase, _ root: URL,
                                      _ config: S3ObjectStoreConfiguration) throws -> ArchiveFileRepository {
        let key = key
        return try ArchiveFileRepository(connectionString: db.connectionString, schema: db.schema,
            configuration: config, spoolDirectory: root.appendingPathComponent("queue"),
            keyProvider: { _, _ in key }, directorySync: { _ in throw MessageArchiveError.database })
    }

    // Catches ignoring defaults, losing the override on reopen, or keying it by message.
    func testDefaultsAndPersistentOverrideApplyToWholeConversation() throws {
        let db = try database(), first = try store(db)
        XCTAssertTrue(try first.conversationFileSavingEnabled(identity: identity, defaultEnabled: true))
        XCTAssertFalse(try first.conversationFileSavingEnabled(identity: identity, defaultEnabled: false))
        try first.setConversationFileSavingEnabled(identity: identity, enabled: false)
        let otherMessage = MessageArchiveIdentity(service: "telegram", accountID: "synthetic-account",
            conversationID: "synthetic-chat", messageID: "")
        let reopened = try store(db)
        XCTAssertFalse(try reopened.conversationFileSavingEnabled(identity: otherMessage, defaultEnabled: true))
        try reopened.setConversationFileSavingEnabled(identity: otherMessage, enabled: true)
        XCTAssertTrue(try first.conversationFileSavingEnabled(identity: identity, defaultEnabled: false))
    }

    // Catches leaking an override across service/account/chat or Unicode normalization.
    func testPolicyIsScopedByExactServiceAccountAndConversationBytes() throws {
        let db = try database(), archive = try store(db)
        let scoped = MessageArchiveIdentity(service: "telegram", accountID: "é", conversationID: "chat", messageID: "1")
        try archive.setConversationFileSavingEnabled(identity: scoped, enabled: false)
        let others = [
            MessageArchiveIdentity(service: "mail", accountID: "é", conversationID: "chat", messageID: "1"),
            MessageArchiveIdentity(service: "telegram", accountID: "e\u{301}", conversationID: "chat", messageID: "1"),
            MessageArchiveIdentity(service: "telegram", accountID: "é", conversationID: "other", messageID: "1")
        ]
        XCTAssertFalse(try archive.conversationFileSavingEnabled(identity: scoped, defaultEnabled: true))
        for other in others {
            XCTAssertTrue(try archive.conversationFileSavingEnabled(identity: other, defaultEnabled: true))
        }
    }

    // Catches plaintext scope storage and swapping one chat's authenticated policy into another.
    func testPolicyMetadataIsEncryptedAndBoundToItsScope() throws {
        let db = try database(), archive = try store(db)
        let other = MessageArchiveIdentity(service: "telegram", accountID: "synthetic-account",
            conversationID: "other-private-chat", messageID: "2")
        try archive.setConversationFileSavingEnabled(identity: identity, enabled: false)
        try archive.setConversationFileSavingEnabled(identity: other, enabled: true)
        guard try archive.conversationFileSavingEnabled(identity: other, defaultEnabled: false) else {
            return XCTFail("Explicit enabled policy was not persisted")
        }
        let rows = try db.execute("SELECT stream_token,ciphertext FROM \"\(db.schema)\".archive_conversation_file_policy ORDER BY stream_token")
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows.joined().joined().contains("synthetic-account"))
        XCTAssertFalse(rows.joined().joined().contains("other-private-chat"))
        guard rows.count == 2 else { return }
        try db.execute("UPDATE \"\(db.schema)\".archive_conversation_file_policy SET ciphertext='\(rows[0][1])' WHERE stream_token='\(rows[1][0])'")
        var failures = 0
        for scope in [identity, other] {
            do { _ = try archive.conversationFileSavingEnabled(identity: scope, defaultEnabled: true) }
            catch { failures += 1 }
        }
        XCTAssertEqual(failures, 1)
    }

    // Catches an invalid/empty scope creating policy and any coupling to text retention.
    func testInvalidPolicyScopeFailsAndDisablingDoesNotChangeTextArchive() throws {
        let db = try database(), archive = try store(db)
        let observation = MessageArchiveObservation(identity: identity, source: .synthetic,
            event: .message(MessageArchiveContent(date: Date(timeIntervalSince1970: 10),
                text: "PERMANENT_SYNTHETIC_TEXT", author: "synthetic", isOutgoing: false)))
        _ = try archive.append([observation])
        for bad in [
            MessageArchiveIdentity(service: "", accountID: "account", conversationID: "chat", messageID: "1"),
            MessageArchiveIdentity(service: "telegram", accountID: "", conversationID: "chat", messageID: "1"),
            MessageArchiveIdentity(service: "telegram", accountID: "account", conversationID: "", messageID: "1")
        ] {
            XCTAssertThrowsError(try archive.setConversationFileSavingEnabled(identity: bad, enabled: true))
            XCTAssertThrowsError(try archive.conversationFileSavingEnabled(identity: bad, defaultEnabled: true))
        }
        try archive.setConversationFileSavingEnabled(identity: identity, enabled: false)
        XCTAssertEqual(try archive.records().map(\.observation), [observation])
    }

    // Catches new disabled admission leaving either a spool receipt or a stored object.
    func testDisabledConversationDoesNotCreateReceiptAndStoredFilesRemainReadable() async throws {
        let config = try config(), db = try database(), root = try directory()
        _ = try store(db)
        let archive = try repository(db, root, config)
        let disabled = try await archive.captureConversationFile(capture(root), identity: identity,
            attachment: attachment, defaultEnabled: false)
        XCTAssertNil(disabled)
        XCTAssertTrue(try queueFiles(root).isEmpty)
        XCTAssertEqual(try db.execute("SELECT count(*) FROM \"\(db.schema)\".archive_file_events"), [["0"]])
        try await archive.setConversationFileSavingEnabled(identity: identity, enabled: true)
        let accepted = try await archive.captureConversationFile(capture(root), identity: identity,
            attachment: attachment, defaultEnabled: false)
        let record = try XCTUnwrap(accepted)
        XCTAssertEqual(record.state, .stored)
        XCTAssertEqual(record.purpose, .conversation(defaultEnabled: false))
        try await archive.setConversationFileSavingEnabled(identity: identity, enabled: false)
        let reopened = try repository(db, root, config)
        let retained = try await reopened.files(identity: identity, attachmentID: attachment.id)
        XCTAssertEqual(retained, [record])
        let exported = root.appendingPathComponent("retained")
        try await reopened.export(record, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data("SYNTHETIC_CONVERSATION_FILE_POLICY".utf8))
    }

    // Catches resume bypassing a newly disabled conversation or deleting its pending bytes.
    func testQueuedConversationIsSkippedWhileDisabledAndResumesAfterReenable() async throws {
        let config = try config(), db = try database(), root = try directory()
        let first = try failedQueueRepository(db, root, config)
        do {
            _ = try await first.captureConversationFile(capture(root), identity: identity,
                attachment: attachment, defaultEnabled: true)
            XCTFail("Expected the published receipt to retain a directory-sync failure")
        } catch let failure as ArchiveFileCaptureFailure { XCTAssertTrue(failure.isQueued) }
        let files = try queueFiles(root)
        XCTAssertEqual(files.filter { $0.pathExtension == "receipt" }.count, 1)
        XCTAssertEqual(files.filter { $0.pathExtension == "envelope" }.count, 1)
        let before = try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        let reopened = try repository(db, root, config)
        try await reopened.setConversationFileSavingEnabled(identity: identity, enabled: false)
        let skipped = try await reopened.resume()
        XCTAssertEqual(skipped, 0)
        let after = try Dictionary(uniqueKeysWithValues: queueFiles(root).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        XCTAssertEqual(after, before)
        let absent = try await reopened.files(identity: identity, attachmentID: attachment.id)
        XCTAssertTrue(absent.isEmpty)
        let receiptURL = try XCTUnwrap(files.first { $0.pathExtension == "receipt" })
        let objectID = try XCTUnwrap(UUID(uuidString: receiptURL.deletingPathExtension().lastPathComponent))
        let vault = try store(db).fileVault()
        let aad = Data("makosh-file-queue-v1|\(vault.id.uuidString)|\(objectID.uuidString)".utf8)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: receiptURL)),
            using: SymmetricKey(data: vault.key), authenticating: aad)
        let queued = try JSONDecoder().decode(ArchiveFileRecord.self, from: clear)
        let remote = try await S3ObjectStore(configuration: config).head(key: queued.objectKey)
        XCTAssertNil(remote, "Disabled resume must leave the owned object absent from S3 (HTTP 404)")
        try await reopened.setConversationFileSavingEnabled(identity: identity, enabled: true)
        let resumed = try await reopened.resume()
        XCTAssertEqual(resumed, 1)
        let records = try await reopened.files(identity: identity, attachmentID: attachment.id)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.purpose, .conversation(defaultEnabled: true))
        XCTAssertTrue(try queueFiles(root).isEmpty)
    }

    // Catches preparation bypassing a disabled chat, or losing local recovery after restart.
    func testDisabledChatPreparationRemainsRecoverableWithoutAnyS3Copy() async throws {
        let config = try config(), db = try database(), root = try directory()
        let archive = try repository(db, root, config)
        try await archive.setConversationFileSavingEnabled(identity: identity, enabled: false)
        let record = try await archive.capture(capture(root), identity: identity, attachment: attachment)
        let remote = try await S3ObjectStore(configuration: config).head(key: record.objectKey)
        XCTAssertNil(remote, "Disabled preparation must never create an S3 object (HTTP 404)")
        let archived = try await archive.files(identity: identity, attachmentID: attachment.id)
        XCTAssertTrue(archived.isEmpty, "Local preparation must not become an S3 archive event")
        let reopened = try repository(db, root, config)
        let initiallyResumed = try await reopened.resume()
        XCTAssertEqual(initiallyResumed, 0)
        let exported = root.appendingPathComponent("prepared")
        try await reopened.export(record, to: exported)
        XCTAssertEqual(try Data(contentsOf: exported), Data("SYNTHETIC_CONVERSATION_FILE_POLICY".utf8))
        try await reopened.setConversationFileSavingEnabled(identity: identity, enabled: true)
        let resumed = try await reopened.resume()
        XCTAssertEqual(resumed, 0, "Local-only preparation must never be promoted by the S3 retry queue")
        let stillAbsent = try await S3ObjectStore(configuration: config).head(key: record.objectKey)
        XCTAssertNil(stillAbsent)
    }

    // Catches accepting a forged pointer, an altered envelope, or permissive local metadata.
    func testLocalPreparationRequiresExactAuthenticatedReceiptAndPayload() async throws {
        let config = try config(), db = try database(), root = try directory()
        let archive = try repository(db, root, config)
        try await archive.setConversationFileSavingEnabled(identity: identity, enabled: false)
        let record = try await archive.capture(capture(root), identity: identity, attachment: attachment)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        var scope = try XCTUnwrap(json["identity"] as? [String: Any])
        scope["accountID"] = "other-account"; json["identity"] = scope
        let forged = try JSONDecoder().decode(ArchiveFileRecord.self, from: JSONSerialization.data(withJSONObject: json))
        let destination = root.appendingPathComponent("refused")
        do { try await archive.export(forged, to: destination); XCTFail("Foreign pointer must be refused") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let receipt = root.appendingPathComponent("queue/" + record.id.uuidString.lowercased() + ".local")
        let authenticated = try Data(contentsOf: receipt)
        XCTAssertNil(authenticated.range(of: Data(identity.accountID.utf8)))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: receipt.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: receipt.path)
        do { try await archive.export(record, to: destination); XCTFail("Permissive receipt must be refused") } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        let ownedReceipt = receipt.appendingPathExtension("owned")
        try FileManager.default.moveItem(at: receipt, to: ownedReceipt)
        try FileManager.default.createSymbolicLink(at: receipt, withDestinationURL: ownedReceipt)
        do { try await archive.export(record, to: destination); XCTFail("Symlink receipt must be refused") } catch {}
        try FileManager.default.removeItem(at: receipt)
        try FileManager.default.moveItem(at: ownedReceipt, to: receipt)
        var altered = authenticated; altered[0] ^= 1
        try altered.write(to: receipt)
        do { try await archive.export(record, to: destination); XCTFail("Altered receipt must be refused") } catch {}
        try authenticated.write(to: receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let envelope = root.appendingPathComponent("queue/" + record.id.uuidString.lowercased() + ".envelope")
        // Local preparation must retain encrypted bytes, rather than only an S3 object.
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
        guard FileManager.default.fileExists(atPath: envelope.path) else { return }
        var bytes = try Data(contentsOf: envelope)
        XCTAssertNil(bytes.range(of: Data("SYNTHETIC_CONVERSATION_FILE_POLICY".utf8)))
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: envelope)
        do { try await archive.export(record, to: destination); XCTFail("Altered payload must be refused") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // Catches the local path bypassing the metadata limits enforced for S3 records.
    func testInvalidPreparationMetadataIsRefusedBeforeCreatingLocalFiles() async throws {
        let config = try config(), db = try database(), root = try directory()
        let archive = try repository(db, root, config)
        try await archive.setConversationFileSavingEnabled(identity: identity, enabled: false)
        let scopes = ["", String(repeating: "m", count: 1025)].map {
            MessageArchiveIdentity(service: identity.service, accountID: identity.accountID,
                conversationID: identity.conversationID, messageID: $0)
        }
        let attachments = [
            MessageArchiveAttachment(id: "", kind: "file", name: "synthetic", size: nil),
            MessageArchiveAttachment(id: String(repeating: "a", count: 1025), kind: "file", name: "synthetic", size: nil),
            MessageArchiveAttachment(id: "synthetic", kind: String(repeating: "k", count: 65), name: "synthetic", size: nil),
            MessageArchiveAttachment(id: "synthetic", kind: "file", name: String(repeating: "n", count: 1025), size: nil)
        ]
        for (scope, metadata) in scopes.map({ ($0, attachment) }) + attachments.map({ (identity, $0) }) {
            do {
                _ = try await archive.capture(capture(root), identity: scope, attachment: metadata)
                XCTFail("Invalid preparation metadata must fail admission")
            } catch {}
        }
        XCTAssertTrue(try queueFiles(root).isEmpty, "Rejected metadata must not publish local payloads or receipts")
    }

    // Catches treating an old untagged receipt as preparation or ignoring its resolved policy.
    func testLegacyQueueRequiresResolverAndRechecksOverride() async throws {
        try await assertLegacyQueue(taggedPreparation: false)
    }
    func testOldTaggedPreparationRequiresResolverAndRechecksOverride() async throws {
        try await assertLegacyQueue(taggedPreparation: true)
    }
    private func assertLegacyQueue(taggedPreparation: Bool) async throws {
        let config = try config(), db = try database(), root = try directory()
        let first = try failedQueueRepository(db, root, config)
        do {
            _ = try await first.capture(capture(root), identity: identity, attachment: attachment)
            XCTFail("Expected published queue receipt")
        } catch let failure as ArchiveFileCaptureFailure { XCTAssertTrue(failure.isQueued) }
        let receiptURL = try XCTUnwrap(queueFiles(root).first { $0.pathExtension == "receipt" })
        let objectID = try XCTUnwrap(UUID(uuidString: receiptURL.deletingPathExtension().lastPathComponent))
        let vault = try store(db).fileVault()
        let aad = Data("makosh-file-queue-v1|\(vault.id.uuidString)|\(objectID.uuidString)".utf8)
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: receiptURL)),
            using: SymmetricKey(data: vault.key), authenticating: aad)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: clear) as? [String: Any])
        if taggedPreparation { legacy["purpose"] = ["preparation": [:]] }
        else { legacy.removeValue(forKey: "purpose") }
        let sealed = try XCTUnwrap(AES.GCM.seal(JSONSerialization.data(withJSONObject: legacy),
            using: SymmetricKey(data: vault.key), authenticating: aad).combined)
        try sealed.write(to: receiptURL)
        let reopened = try repository(db, root, config)
        let unresolved = try await reopened.resume()
        XCTAssertEqual(unresolved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        try await reopened.setConversationFileSavingEnabled(identity: identity, enabled: false)
        let disabled = try await reopened.resume(legacyConversationDefault: { _ in true })
        XCTAssertEqual(disabled, 0)
        XCTAssertEqual(try Data(contentsOf: receiptURL), sealed)
        let queued = try JSONDecoder().decode(ArchiveFileRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        let absent = try await S3ObjectStore(configuration: config).head(key: queued.objectKey)
        XCTAssertNil(absent)
        try await reopened.setConversationFileSavingEnabled(identity: identity, enabled: true)
        let resumed = try await reopened.resume(legacyConversationDefault: { _ in false })
        XCTAssertEqual(resumed, 1)
        let records = try await reopened.files(identity: identity, attachmentID: attachment.id)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.purpose, taggedPreparation ? .preparation : nil,
            "Legacy immutable metadata must retain its authenticated bytes")
    }
}
