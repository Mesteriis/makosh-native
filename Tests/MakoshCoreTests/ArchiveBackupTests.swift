import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import MakoshCore

final class ArchiveBackupTests: XCTestCase {
    func testReadOnlyArchiveCannotAppendOrCreateAnEmptyArchive() throws {
        let fixture = try fixture()
        let read = try MessageArchiveStore(connectionString: fixture.db.connectionString, schema: fixture.db.schema, readOnly: true) { id, create in
            XCTAssertFalse(create)
            return try XCTUnwrap(fixture.keys.access.lookup(id))
        }
        XCTAssertEqual(try read.records().count, 1)
        let value = MessageArchiveObservation(identity: fixture.identity, observedAt: Date(), source: .synthetic, event: .deleted)
        XCTAssertThrowsError(try read.append([value]))
        let empty = fixture.target
        XCTAssertThrowsError(try MessageArchiveStore(connectionString: fixture.db.connectionString, schema: empty, readOnly: true) { _, _ in Data(repeating: 9, count: 32) })
        XCTAssertEqual(try fixture.db.execute("SELECT 1 FROM pg_namespace WHERE nspname='\(empty)'"), [])
    }
    private func aclEntries(_ fd: Int32) throws -> Int {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return 0 }
            throw BackupTestFailure.refused
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?, cursor = ACL_FIRST_ENTRY.rawValue, count = 0
        while acl_get_entry(acl, cursor, &entry) == 0 { count += 1; cursor = ACL_NEXT_ENTRY.rawValue }
        return count
    }
    func testNewPrivateFilesAndDirectoriesDoNotInheritReadableACLs() throws {
        let workspace = try ArchiveBackupWorkspace(), parent = try workspace.directory.createDirectory("acl-parent")
        let chmod = Process(); chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read,search,file_inherit,directory_inherit", parent.url.path]
        chmod.standardOutput = FileHandle.nullDevice; chmod.standardError = FileHandle.nullDevice
        try chmod.run(); chmod.waitUntilExit(); XCTAssertEqual(chmod.terminationStatus, 0)
        let file = try parent.file("synthetic-key", create: true)
        try file.write(Data("synthetic-only".utf8))
        let child = try parent.createDirectory("private-child")
        XCTAssertEqual(try aclEntries(file.fd), 0)
        XCTAssertEqual(try aclEntries(child.fd), 0)
    }
    func testWritableOutputParentOrAncestorRefusesBeforeSourceKeyAccess() async throws {
        for privateChild in [false, true] {
            let fixture = try fixture()
            let output = privateChild ? fixture.root.appendingPathComponent("private-child") : fixture.root
            if privateChild { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.root.path)
            let package = output.appendingPathComponent("private.makoshbackup"), recovery = output.appendingPathComponent("private.makoshkey")
            do {
                _ = try await ArchiveBackup.export(connectionString: fixture.db.connectionString, schema: fixture.db.schema,
                    to: package, recoveryKey: recovery, keys: fixture.keys.access)
                XCTFail("Untrusted directory writes must refuse")
            } catch let error as ArchiveBackupError { XCTAssertEqual(error, .invalid) }
            XCTAssertEqual(fixture.keys.reads, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        }
    }
    func testUninitializedArchiveExportDoesNotCreateVaultKeyOrOutput() async throws {
        let db = try PostgresTestDatabase(), keys = BackupTestKeys()
        addTeardownBlock { try db.cleanup() }
        let root = try ArchiveBackupWorkspace()
        let package = root.directory.url.appendingPathComponent("empty.makoshbackup"), recovery = root.directory.url.appendingPathComponent("empty.makoshkey")
        do {
            _ = try await ArchiveBackup.export(connectionString: db.connectionString, schema: db.schema, to: package, recoveryKey: recovery, keys: keys.access)
            XCTFail("A backup cannot create a new empty vault")
        } catch let error as ArchiveBackupError { XCTAssertEqual(error, .noArchive) }
        catch { XCTFail("Expected explicit empty archive result: \(error)") }
        XCTAssertEqual(keys.reads, 0); XCTAssertEqual(keys.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertEqual(try db.execute("SELECT to_regclass('\"\(db.schema)\".archive_metadata')::text"), [[""]])
    }
    private struct Fixture {
        let db: PostgresTestDatabase, root: URL, store: MessageArchiveStore, keys: BackupTestKeys
        let storage: BackupTestStorage
        let identity = MessageArchiveIdentity(service: "telegram", accountID: "synthetic-account", conversationID: "synthetic-chat", messageID: "0:1")
        var package: URL { root.appendingPathComponent("copy.makoshbackup") }
        var recovery: URL { root.appendingPathComponent("separate.makoshkey") }
        var target: String { db.schema + "_restored" }
    }
    private func fixture() throws -> Fixture {
        let db = try PostgresTestDatabase(), keys = BackupTestKeys()
        addTeardownBlock { try db.cleanup() }
        let root = try ArchiveBackupDirectory.temporaryBase().appendingPathComponent("makosh-backup-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let store = try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { id, _ in
            let value = Data(repeating: 0x43, count: 32); try keys.access.install(id, value); return value
        }
        let value = Fixture(db: db, root: root, store: store, keys: keys, storage: BackupTestStorage("source"))
        let target = value.target
        addTeardownBlock { try db.execute("DROP SCHEMA IF EXISTS \"\(target)\" CASCADE") }
        _ = try store.append([.init(identity: value.identity, observedAt: Date(timeIntervalSince1970: 20), source: .synthetic,
            event: .message(.init(date: Date(timeIntervalSince1970: 10), text: "Synthetic initial text", author: "QA", isOutgoing: false)))])
        return value
    }
    @discardableResult private func export(_ fixture: Fixture) async throws -> ArchiveBackupSummary {
        try await ArchiveBackup.export(connectionString: fixture.db.connectionString, schema: fixture.db.schema, storage: fixture.storage,
            to: fixture.package, recoveryKey: fixture.recovery, keys: fixture.keys.access)
    }
    private func addFile(_ fixture: Fixture, chat: String = "synthetic-chat") async throws -> ArchiveFileRecord {
        let vault = try fixture.store.fileVault(), id = UUID()
        let input = fixture.root.appendingPathComponent(id.uuidString + ".input")
        let encrypted = fixture.root.appendingPathComponent(id.uuidString + ".cipher")
        let clear = Data("Synthetic file payload".utf8); try clear.write(to: input)
        let receipt = try ArchiveFileCapture(file: input, byteCount: Int64(clear.count)).seal(to: encrypted, key: vault.key, objectID: id)
        let identity = MessageArchiveIdentity(service: "telegram", accountID: fixture.identity.accountID, conversationID: chat, messageID: "0:1")
        var record = ArchiveFileRecord(id: id, identity: identity, attachment: .init(id: id.uuidString, kind: "document", name: "Synthetic.txt", size: Int64(clear.count)),
            objectKey: "vaults/\(vault.id.uuidString.lowercased())/files/\(id.uuidString.lowercased())", storageID: fixture.storage.storageID, receipt: receipt,
            capturedAt: Date(timeIntervalSince1970: 30), state: .pending, purpose: .conversation(defaultEnabled: true))
        _ = try fixture.store.appendFile(record); record.state = .stored; _ = try fixture.store.appendFile(record)
        await fixture.storage.seed(key: record.objectKey, data: try Data(contentsOf: encrypted)); return record
    }
    func testRestorePreservesEditsDeletionSequencesAndAppendsBeyondRestoredHistory() async throws {
        let fixture = try fixture(), targetKeys = BackupTestKeys()
        _ = try fixture.store.append([
            .init(identity: fixture.identity, source: .synthetic, event: .message(.init(date: Date(timeIntervalSince1970: 10), text: "Changed text", author: "QA", isOutgoing: false))),
            .init(identity: fixture.identity, source: .synthetic, event: .deleted)
        ])
        let expected = try fixture.store.records(), summary = try await export(fixture)
        let inspection = try ArchiveBackup.inspectReceipt(package: fixture.package, recoveryKey: fixture.recovery)
        do {
            let restoredSummary = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
                schema: fixture.target, storage: nil, keys: targetKeys.access, expectedFingerprint: inspection.fingerprint)
            XCTAssertEqual(restoredSummary, summary)
        } catch { return XCTFail("Restore failed before producing the new archive: \(error)") }
        let restored = try MessageArchiveStore(connectionString: fixture.db.connectionString, schema: fixture.target) { id, creation in
            XCTAssertFalse(creation); return try XCTUnwrap(targetKeys.access.lookup(id))
        }
        XCTAssertEqual(try restored.records(), expected)
        XCTAssertThrowsError(try fixture.db.execute("DELETE FROM \"\(fixture.target)\".archive_events"))
        _ = try restored.append([.init(identity: fixture.identity, source: .synthetic, event: .removedFromSource)])
        XCTAssertGreaterThan(try XCTUnwrap(restored.records().first?.sequence), try XCTUnwrap(expected.first?.sequence))
        XCTAssertEqual(try fixture.store.records(), expected)
    }
    func testExistingSchemaAndDifferentExistingVaultKeyRefuseBeforeInstallation() async throws {
        let fixture = try fixture(), targetKeys = BackupTestKeys()
        let summary = try await export(fixture)
        for schema in [fixture.db.schema, fixture.target] {
            if schema == fixture.target { try targetKeys.access.install(summary.vaultID, Data(repeating: 0x99, count: 32)) }
            do {
                _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
                    schema: schema, storage: nil, keys: targetKeys.access)
                XCTFail("Conflict must refuse restoration")
            } catch let error as ArchiveBackupError { XCTAssertEqual(error, .conflict) }
        }
        XCTAssertEqual(try fixture.store.records().count, 1)
        XCTAssertEqual(try fixture.db.execute("SELECT count(*) FROM pg_namespace WHERE nspname='\(fixture.target)'"), [["0"]])
    }
    func testAnyMissingOffObjectPreventsEveryNewS3CopyAndSchemaPublication() async throws {
        let fixture = try fixture(), target = BackupTestStorage("destination"), targetKeys = BackupTestKeys()
        _ = try await addFile(fixture)
        let off = try await addFile(fixture, chat: "off-chat")
        try fixture.store.setConversationFileSavingEnabled(identity: off.identity, enabled: false)
        _ = try await export(fixture)
        do {
            _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
                schema: fixture.target, storage: target, keys: targetKeys.access)
            XCTFail("OFF cannot authorize a new S3 copy")
        } catch let error as ArchiveBackupError { XCTAssertEqual(error, .disabledObjectMissing) }
        let puts = await target.puts
        XCTAssertEqual(puts, 0); XCTAssertEqual(targetKeys.count, 0)
        XCTAssertEqual(try fixture.db.execute("SELECT count(*) FROM pg_namespace WHERE nspname='\(fixture.target)'"), [["0"]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.package.path))
    }
    func testNewerCurrentOffPolicyOverridesOlderBackupOnBeforeEveryCopy() async throws {
        let fixture = try fixture(), target = BackupTestStorage("destination"), targetKeys = BackupTestKeys()
        _ = try await addFile(fixture); _ = try await export(fixture)
        do {
            _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
                schema: fixture.target, storage: target, keys: targetKeys.access, currentPolicy: { _ in false })
            XCTFail("An old backup cannot enable current OFF")
        } catch let error as ArchiveBackupError { XCTAssertEqual(error, .disabledObjectMissing) }
        let puts = await target.puts; XCTAssertEqual(puts, 0); XCTAssertEqual(targetKeys.count, 0)
    }
    func testCurrentOffPolicyWithoutFilesSurvivesOlderBackupOn() async throws {
        let fixture = try fixture(), targetKeys = BackupTestKeys()
        try fixture.store.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
        _ = try await export(fixture)
        _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
            schema: fixture.target, storage: nil, keys: targetKeys.access, currentOffPolicies: { [identity = fixture.identity] in [identity] })
        let restored = try MessageArchiveStore(connectionString: fixture.db.connectionString, schema: fixture.target) { id, _ in try XCTUnwrap(targetKeys.access.lookup(id)) }
        XCTAssertFalse(try restored.conversationFileSavingEnabled(identity: fixture.identity, defaultEnabled: true))
    }
    func testExplicitPolicyReadsDistinguishMissingAndEnumerateOffScopesOnly() throws {
        let fixture = try fixture()
        XCTAssertNil(try fixture.store.explicitConversationFileSavingEnabled(identity: fixture.identity))
        try fixture.store.setConversationFileSavingEnabled(identity: fixture.identity, enabled: false)
        XCTAssertEqual(try fixture.store.explicitConversationFileSavingEnabled(identity: fixture.identity), false)
        let disabled = try fixture.store.disabledConversationFilePolicies()
        XCTAssertEqual(disabled.count, 1)
        XCTAssertEqual(disabled.first?.conversationID, fixture.identity.conversationID)
        try fixture.store.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
        XCTAssertEqual(try fixture.store.explicitConversationFileSavingEnabled(identity: fixture.identity), true)
        XCTAssertTrue(try fixture.store.disabledConversationFilePolicies().isEmpty)
    }
    func testKeyInstallationFailureRollsBackEntireNewSchemaAndPreservesSource() async throws {
        let fixture = try fixture(); _ = try await export(fixture)
        let keys = ArchiveBackupKeys(lookup: { _ in nil }, install: { _, _ in throw BackupTestFailure.refused })
        do {
            _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
                schema: fixture.target, storage: nil, keys: keys)
            XCTFail("Rejected key installation must roll back")
        } catch {}
        XCTAssertEqual(try fixture.db.execute("SELECT count(*) FROM pg_namespace WHERE nspname='\(fixture.target)'"), [["0"]])
        XCTAssertEqual(try fixture.store.records().count, 1)
    }
    func testSchemaRaceAfterObjectCopyCannotPublishIntoAnExistingNamespace() async throws {
        let fixture = try fixture(), targetKeys = BackupTestKeys(), db = fixture.db, schema = fixture.target
        _ = try await addFile(fixture); _ = try await export(fixture)
        let target = BackupTestStorage("destination", beforePut: { try db.execute("CREATE SCHEMA \"\(schema)\"") })
        do {
            _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: db.connectionString,
                schema: schema, storage: target, keys: targetKeys.access)
            XCTFail("A raced namespace must remain untouched")
        } catch let error as ArchiveBackupError { XCTAssertEqual(error, .conflict) }
        XCTAssertEqual(targetKeys.count, 0)
        XCTAssertEqual(try db.execute("SELECT to_regclass('\"\(schema)\".archive_metadata')::text"), [[""]])
    }
    func testSnapshotRemainsConsistentWhileAnotherConnectionAppends() throws {
        let fixture = try fixture(), access = fixture.keys.access
        let concurrent = try MessageArchiveStore(connectionString: fixture.db.connectionString, schema: fixture.db.schema) { id, _ in try XCTUnwrap(access.lookup(id)) }
        let vault = try fixture.store.fileVault(), rootKey = try XCTUnwrap(access.lookup(vault.id))
        let validator = try ArchiveBackupRowValidator(vaultID: vault.id, rootKey: rootKey)
        var appended = false
        try fixture.store.writeBackupSnapshot { row in
            try validator.accept(row)
            if row.table == .events, !appended {
                appended = true
                _ = try concurrent.append([.init(identity: fixture.identity, source: .synthetic, event: .deleted)])
            }
        }
        _ = try validator.finish()
        XCTAssertEqual(validator.counts[ArchiveBackupTable.events.rawValue], 1)
        XCTAssertEqual(try fixture.store.records().count, 2)
    }
    func testDatabaseStreamCrossesEncryptedPartBoundaryWithoutLoadingWholeArchive() async throws {
        let fixture = try fixture(), text = String(repeating: "x", count: 3 * 1024 * 1024)
        for index in 0..<8 {
            _ = try fixture.store.append([.init(identity: fixture.identity, source: .synthetic,
                event: .message(.init(date: Date(timeIntervalSince1970: Double(index)), text: "\(index)" + text, author: "QA", isOutgoing: false)))])
        }
        let summary = try await export(fixture)
        XCTAssertEqual(summary.messageVersions, 9)
        XCTAssertGreaterThan(summary.databaseBytes, 32 * 1024 * 1024)
        XCTAssertGreaterThan(try FileManager.default.contentsOfDirectory(atPath: fixture.package.appendingPathComponent("database").path).count, 1)
        XCTAssertEqual(try ArchiveBackup.inspect(package: fixture.package, recoveryKey: fixture.recovery), summary)
    }
    func testIncompleteFileInventoryDoesNotPublishPackageOrRecoveryKey() async throws {
        let fixture = try fixture(), record = try await addFile(fixture), id = UUID(), vault = try fixture.store.fileVault()
        let receipt = ArchiveFileEnvelopeReceipt(byteCount: record.byteCount, sha256: record.sha256, plaintextByteCount: record.plaintextByteCount, plaintextSHA256: record.plaintextSHA256)
        let incomplete = ArchiveFileRecord(id: id, identity: record.identity, attachment: record.attachment,
            objectKey: "vaults/\(vault.id.uuidString.lowercased())/files/\(id.uuidString.lowercased())", storageID: record.storageID,
            receipt: receipt, state: .pending, purpose: .conversation(defaultEnabled: true))
        _ = try fixture.store.appendFile(incomplete)
        do { _ = try await export(fixture); XCTFail("Unstored receipt cannot produce a complete backup") }
        catch let error as ArchiveBackupError { XCTAssertEqual(error, .incomplete) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.package.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.recovery.path))
    }
    func testChangedPackageAfterInspectionCannotAuthorizeRestoringDifferentSnapshot() async throws {
        let fixture = try fixture(), targetKeys = BackupTestKeys()
        _ = try await export(fixture)
        let receipt = try ArchiveBackup.inspectReceipt(package: fixture.package, recoveryKey: fixture.recovery)
        XCTAssertTrue(ArchiveBackupCryptography.validHash(receipt.fingerprint))
        _ = try fixture.store.append([.init(identity: fixture.identity, source: .synthetic, event: .deleted)])
        let second = fixture.root.appendingPathComponent("second.makoshbackup"), secondKey = fixture.root.appendingPathComponent("second.makoshkey")
        _ = try await ArchiveBackup.export(connectionString: fixture.db.connectionString, schema: fixture.db.schema, storage: fixture.storage,
            to: second, recoveryKey: secondKey, keys: fixture.keys.access)
        do {
            _ = try await ArchiveBackup.restore(package: second, recoveryKey: secondKey, connectionString: fixture.db.connectionString,
                schema: fixture.target, storage: nil, keys: targetKeys.access, expectedFingerprint: receipt.fingerprint)
            XCTFail("Inspection must not authorize a different snapshot")
        } catch let error as ArchiveBackupError { XCTAssertEqual(error, .changed) }
        catch { XCTFail("Unexpected restoration failure: \(error)") }
        XCTAssertEqual(targetKeys.count, 0)
        XCTAssertEqual(try fixture.db.execute("SELECT count(*) FROM pg_namespace WHERE nspname='\(fixture.target)'"), [["0"]])
    }
    func testPolicyReaderUsesExistingEncryptedArchiveAndDoesNotCreateKeysForEmptySchema() async throws {
        let db = try PostgresTestDatabase(), emptyKeys = BackupTestKeys()
        addTeardownBlock { try db.cleanup() }
        let empty = ArchiveBackupPolicyReader(connectionString: db.connectionString, schema: db.schema, keys: emptyKeys.access)
        let identity = MessageArchiveIdentity(service: "telegram", accountID: "QA", conversationID: "QA", messageID: "1")
        let absent = try await empty.policy(identity), disabledEmpty = try await empty.disabledPolicies()
        XCTAssertNil(absent); XCTAssertTrue(disabledEmpty.isEmpty); XCTAssertEqual(emptyKeys.reads, 0)
        XCTAssertEqual(try db.execute("SELECT to_regclass('\"\(db.schema)\".archive_metadata')::text"), [[""]])
        let fixture = try fixture()
        try fixture.store.setConversationFileSavingEnabled(identity: fixture.identity, enabled: false)
        let reader = ArchiveBackupPolicyReader(connectionString: fixture.db.connectionString, schema: fixture.db.schema, keys: fixture.keys.access)
        let policy = try await reader.policy(fixture.identity), scopes = try await reader.disabledPolicies()
        XCTAssertEqual(policy, false); XCTAssertEqual(scopes.count, 1)
        XCTAssertEqual(scopes.first?.conversationID, fixture.identity.conversationID)
    }
    func testPreviouslyObservedPolicyArchiveDisappearanceFailsClosed() async throws {
        let fixture = try fixture()
        try fixture.store.setConversationFileSavingEnabled(identity: fixture.identity, enabled: false)
        let reader = ArchiveBackupPolicyReader(connectionString: fixture.db.connectionString, schema: fixture.db.schema, keys: fixture.keys.access)
        let policy = try await reader.policy(fixture.identity); XCTAssertEqual(policy, false)
        try fixture.db.execute("DROP TABLE \"\(fixture.db.schema)\".archive_metadata")
        for _ in 0..<2 {
            do { _ = try await reader.policy(fixture.identity); XCTFail("A vanished known policy source cannot become permissive absence") } catch {}
        }
    }
    func testCancellationDuringPolicyReadPreventsStartingNewObjectCopy() async throws {
        let fixture = try fixture(), target = BackupTestStorage("destination"), targetKeys = BackupTestKeys()
        _ = try await addFile(fixture); _ = try await export(fixture)
        let policy = BackupPolicyCancellation(), package = fixture.package, recovery = fixture.recovery
        let connection = fixture.db.connectionString, schema = fixture.target, keys = targetKeys.access
        let task = Task {
            try await ArchiveBackup.restore(package: package, recoveryKey: recovery, connectionString: connection, schema: schema,
                storage: target, keys: keys, currentPolicy: { _ in await policy.next() })
        }
        do { _ = try await task.value; XCTFail("Cancelled preparation must stop") }
        catch is CancellationError {}
        let puts = await target.puts; XCTAssertEqual(puts, 0)
        XCTAssertEqual(targetKeys.count, 0)
    }
    private func rewritePackage(_ fixture: Fixture, transform: ([ArchiveBackupRow], ArchiveBackupCryptography) throws -> [ArchiveBackupRow]) throws {
        let verified = try ArchiveBackupVerified.open(package: fixture.package, recoveryKey: fixture.recovery)
        let root = try ArchiveBackupDirectory(fixture.package)
        let (id, recovery, old, _) = try ArchiveBackupFormat.readHeader(root, recoveryKey: fixture.recovery)
        let reader = try ArchiveBackupRecordReader(verified.database)
        var rows: [ArchiveBackupRow] = []
        while let row = try reader.next() { rows.append(row); guard rows.count < 50 else { throw BackupTestFailure.refused } }
        rows = try transform(rows, ArchiveBackupCryptography(vaultID: old.vaultID, rootKey: old.rootKey))
        try FileManager.default.removeItem(at: fixture.package.appendingPathComponent("database"))
        let parts = try root.createDirectory("database")
        let writer = ArchiveBackupPartWriter(directory: parts, workspace: verified.workspace.directory, recovery: recovery, id: id)
        var counts = Dictionary(uniqueKeysWithValues: ArchiveBackupTable.allCases.map { ($0.rawValue, Int64(0)) })
        for row in rows { try writer.write(ArchiveBackupRecordReader.frame(row)); counts[row.table.rawValue, default: 0] += 1 }
        let digest = try writer.finish()
        let header = ArchiveBackupHeader(vaultID: old.vaultID, rootKey: old.rootKey, partCount: writer.partCount,
            databaseBytes: writer.totalBytes, databaseHash: digest, counts: counts, objectCount: old.objectCount,
            objectBytes: old.objectBytes, sourceStorageID: old.sourceStorageID)
        try ArchiveBackupFormat.headerData(header, recovery: recovery, id: id).write(to: fixture.package.appendingPathComponent("header.json"))
    }
    func testAuthenticatedDuplicateRowsFailBeforeAnyTargetWrite() async throws {
        let fixture = try fixture(), target = BackupTestStorage("destination"), targetKeys = BackupTestKeys()
        _ = try await addFile(fixture); _ = try await export(fixture)
        try rewritePackage(fixture) { rows, _ in
            var rows = rows
            let event = try XCTUnwrap(rows.first { $0.table == .events })
            let index = try XCTUnwrap(rows.firstIndex { $0.table == .receipts })
            rows.insert(event, at: index); return rows
        }
        do {
            _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
                schema: fixture.target, storage: target, keys: targetKeys.access)
            XCTFail("Authenticated duplicates must still refuse")
        } catch {}
        let puts = await target.puts; XCTAssertEqual(puts, 0); XCTAssertEqual(targetKeys.count, 0)
        XCTAssertEqual(try fixture.db.execute("SELECT count(*) FROM pg_namespace WHERE nspname='\(fixture.target)'"), [["0"]])
    }
    func testAuthenticatedObjectPathEscapeFailsBeforeAnyTargetWrite() async throws {
        let fixture = try fixture(), target = BackupTestStorage("destination"), targetKeys = BackupTestKeys()
        _ = try await addFile(fixture); _ = try await export(fixture)
        try rewritePackage(fixture) { rows, crypto in
            try rows.map { row in
                guard row.table == .files else { return row }
                var values = row.values
                let id = try XCTUnwrap(UUID(uuidString: values[1])), token = "file-\(id.uuidString)-\(values[2])"
                var record = try XCTUnwrap(JSONSerialization.jsonObject(with: crypto.open(values[4], token: token)) as? [String: Any])
                record["objectKey"] = "../../outside"
                values[4] = try crypto.seal(JSONSerialization.data(withJSONObject: record, options: .sortedKeys), token: token)
                return .init(table: .files, values: values)
            }
        }
        XCTAssertThrowsError(try ArchiveBackup.inspect(package: fixture.package, recoveryKey: fixture.recovery))
        do {
            _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
                schema: fixture.target, storage: target, keys: targetKeys.access)
            XCTFail("Escaping object keys must refuse")
        } catch {}
        let puts = await target.puts; XCTAssertEqual(puts, 0); XCTAssertEqual(targetKeys.count, 0)
    }
    func testObjectCorruptionFailsBeforeAnyTargetWrite() async throws {
        let fixture = try fixture(), target = BackupTestStorage("destination"), targetKeys = BackupTestKeys()
        let record = try await addFile(fixture); _ = try await export(fixture)
        let file = fixture.package.appendingPathComponent("objects").appendingPathComponent(ArchiveBackupFormat.objectName(record.id))
        var data = try Data(contentsOf: file); data[data.count - 1] ^= 1; try data.write(to: file)
        do {
            _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
                schema: fixture.target, storage: target, keys: targetKeys.access)
            XCTFail("Object corruption must refuse")
        } catch {}
        let puts = await target.puts; XCTAssertEqual(puts, 0); XCTAssertEqual(targetKeys.count, 0)
        XCTAssertEqual(try fixture.db.execute("SELECT count(*) FROM pg_namespace WHERE nspname='\(fixture.target)'"), [["0"]])
    }
    func testOnObjectMigratesAndOriginalFileReceiptRemainsUsableThroughAuthenticatedAlias() async throws {
        let fixture = try fixture(), target = BackupTestStorage("destination"), targetKeys = BackupTestKeys()
        let record = try await addFile(fixture), summary = try await export(fixture)
        do {
            let restoredSummary = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
                schema: fixture.target, storage: target, keys: targetKeys.access)
            XCTAssertEqual(restoredSummary, summary)
        } catch { return XCTFail("Allowed object migration failed: \(error)") }
        let puts = await target.puts; XCTAssertEqual(puts, 1)
        let restored = try MessageArchiveStore(connectionString: fixture.db.connectionString, schema: fixture.target) { id, _ in try XCTUnwrap(targetKeys.access.lookup(id)) }
        XCTAssertEqual(try restored.files(identity: record.identity, attachmentID: record.attachment.id), [record])
        XCTAssertTrue(try restored.acceptsStorageAlias(source: record.storageID, destination: target.storageID))
        XCTAssertThrowsError(try fixture.db.execute("TRUNCATE \"\(fixture.target)\".archive_storage_aliases"))
    }
    func testExistingOffObjectIsReusedAndNewerOffPolicyPersists() async throws {
        let fixture = try fixture(), targetKeys = BackupTestKeys()
        let record = try await addFile(fixture); _ = try await export(fixture)
        _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
            schema: fixture.target, storage: fixture.storage, keys: targetKeys.access, currentPolicy: { _ in false })
        let puts = await fixture.storage.puts; XCTAssertEqual(puts, 0)
        let restored = try MessageArchiveStore(connectionString: fixture.db.connectionString, schema: fixture.target) { id, _ in try XCTUnwrap(targetKeys.access.lookup(id)) }
        XCTAssertFalse(try restored.conversationFileSavingEnabled(identity: record.identity, defaultEnabled: true))
    }
    func testLatePolicyChangeStopsFurtherCopiesAndDoesNotPublishArchiveOrKey() async throws {
        let fixture = try fixture(), target = BackupTestStorage("destination"), targetKeys = BackupTestKeys()
        _ = try await addFile(fixture); _ = try await addFile(fixture); _ = try await export(fixture)
        let policy = BackupPolicySwitch()
        do {
            _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
                schema: fixture.target, storage: target, keys: targetKeys.access, currentPolicy: { _ in await policy.next() })
            XCTFail("A late OFF must stop subsequent copies")
        } catch let error as ArchiveBackupError { XCTAssertEqual(error, .policyChanged) }
        let puts = await target.puts; XCTAssertEqual(puts, 1)
        XCTAssertEqual(targetKeys.count, 0)
        XCTAssertEqual(try fixture.db.execute("SELECT count(*) FROM pg_namespace WHERE nspname='\(fixture.target)'"), [["0"]])
    }
    func testRealPostgresS3RestorationAndFileExportAcrossEndpointIdentityChange() async throws {
        let fixture = try fixture(), targetKeys = BackupTestKeys()
        let configPath = try XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])
        let sourceConfig = try S3ConfigurationFile.read(URL(fileURLWithPath: configPath))
        let endpoint = sourceConfig.endpoint.hasSuffix("/") ? String(sourceConfig.endpoint.dropLast()) : sourceConfig.endpoint + "/"
        let destinationConfig = try S3ObjectStoreConfiguration(endpoint: endpoint, region: sourceConfig.region, bucket: sourceConfig.bucket,
            accessKeyID: sourceConfig.accessKeyID, secretAccessKey: sourceConfig.secretAccessKey)
        let sourceKeys = fixture.keys.access, destinationKeys = targetKeys.access
        let repository = try ArchiveFileRepository(connectionString: fixture.db.connectionString, schema: fixture.db.schema, configuration: sourceConfig,
            spoolDirectory: fixture.root.appendingPathComponent("source-queue"), keyProvider: { id, _ in
                guard let key = try sourceKeys.lookup(id) else { throw MessageArchiveError.keyUnavailable }; return key
            })
        let input = fixture.root.appendingPathComponent("real-source.txt"), bytes = Data("Synthetic real S3 backup roundtrip\n".utf8)
        try bytes.write(to: input)
        let record = try await repository.capture(ArchiveFileCapture(file: input, byteCount: Int64(bytes.count)), identity: fixture.identity,
            attachment: .init(id: "real-s3-file", kind: "document", name: "Synthetic.txt", size: Int64(bytes.count)))
        _ = try await ArchiveBackup.export(connectionString: fixture.db.connectionString, schema: fixture.db.schema, configuration: sourceConfig,
            to: fixture.package, recoveryKey: fixture.recovery, keys: sourceKeys)
        _ = try await ArchiveBackup.restore(package: fixture.package, recoveryKey: fixture.recovery, connectionString: fixture.db.connectionString,
            schema: fixture.target, configuration: destinationConfig, keys: destinationKeys)
        let restored = try ArchiveFileRepository(connectionString: fixture.db.connectionString, schema: fixture.target, configuration: destinationConfig,
            spoolDirectory: fixture.root.appendingPathComponent("restored-queue"), keyProvider: { id, _ in
                guard let key = try destinationKeys.lookup(id) else { throw MessageArchiveError.keyUnavailable }; return key
            })
        let output = fixture.root.appendingPathComponent("real-restored.txt")
        do { try await restored.export(record, to: output) }
        catch { return XCTFail("Restored ciphertext cannot be exported through its authenticated storage alias: \(error)") }
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }
    func testWrongRecoveryCorruptHeaderTruncatedDatabaseAndUnexpectedMembersFailInspection() async throws {
        let fixture = try fixture(); _ = try await export(fixture)
        let wrong = fixture.root.appendingPathComponent("wrong.makoshkey")
        let recovery = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.recovery)) as! [String: Any]
        var changed = recovery; changed["key"] = Data(repeating: 0, count: 32).base64EncodedString()
        try JSONSerialization.data(withJSONObject: changed).write(to: wrong)
        XCTAssertThrowsError(try ArchiveBackup.inspect(package: fixture.package, recoveryKey: wrong))
        let header = fixture.package.appendingPathComponent("header.json"), original = try Data(contentsOf: header)
        try Data([1, 2, 3]).write(to: header)
        XCTAssertThrowsError(try ArchiveBackup.inspect(package: fixture.package, recoveryKey: fixture.recovery))
        try original.write(to: header)
        let part = fixture.package.appendingPathComponent("database/00000000.part"), originalPart = try Data(contentsOf: part)
        try originalPart.dropLast().write(to: part)
        XCTAssertThrowsError(try ArchiveBackup.inspect(package: fixture.package, recoveryKey: fixture.recovery))
        try originalPart.write(to: part)
        let extra = fixture.package.appendingPathComponent("unexpected")
        try Data([1]).write(to: extra)
        XCTAssertThrowsError(try ArchiveBackup.inspect(package: fixture.package, recoveryKey: fixture.recovery))
        try FileManager.default.removeItem(at: extra)
        XCTAssertNoThrow(try ArchiveBackup.inspect(package: fixture.package, recoveryKey: fixture.recovery))
    }
    func testOutputCollisionAndSymlinkedPathsNeverOverwriteOrFollow() async throws {
        let fixture = try fixture(); _ = try await export(fixture)
        let original = try Data(contentsOf: fixture.recovery)
        do { _ = try await export(fixture); XCTFail("Existing backup must remain intact") } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.recovery), original)
        let linked = fixture.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.package)
        XCTAssertThrowsError(try ArchiveBackup.inspect(package: linked, recoveryKey: fixture.recovery))
        let keyLink = fixture.root.appendingPathComponent("linked.makoshkey")
        try FileManager.default.createSymbolicLink(at: keyLink, withDestinationURL: fixture.recovery)
        XCTAssertThrowsError(try ArchiveBackup.inspect(package: fixture.package, recoveryKey: keyLink))
    }
    func testEncryptedSnapshotExportsObservedVersionsAndSeparateRecoveryKey() async throws {
        let db = try PostgresTestDatabase(), keys = BackupTestKeys()
        addTeardownBlock { try db.cleanup() }
        let root = try ArchiveBackupDirectory.temporaryBase().appendingPathComponent("makosh-backup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let store = try MessageArchiveStore(connectionString: db.connectionString, schema: db.schema) { id, _ in
            let value = Data(repeating: 0x43, count: 32); try keys.access.install(id, value); return value
        }
        let identity = MessageArchiveIdentity(service: "telegram", accountID: "synthetic-account", conversationID: "synthetic-chat", messageID: "0:1")
        _ = try store.append([.init(identity: identity, observedAt: Date(timeIntervalSince1970: 20), source: .synthetic,
            event: .message(.init(date: Date(timeIntervalSince1970: 10), text: "Synthetic permanent history", author: "QA", isOutgoing: false)))])
        let package = root.appendingPathComponent("copy.makoshbackup"), recovery = root.appendingPathComponent("separate.makoshkey")
        let result = try await ArchiveBackup.export(connectionString: db.connectionString, schema: db.schema, to: package, recoveryKey: recovery, keys: keys.access)
        XCTAssertEqual(result.messageVersions, 1)
        XCTAssertEqual(result.files, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        guard FileManager.default.fileExists(atPath: package.path), FileManager.default.fileExists(atPath: recovery.path) else { return }
        XCTAssertEqual(try ArchiveBackup.inspect(package: package, recoveryKey: recovery), result)
        XCTAssertEqual(try store.records().count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: recovery.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(try Data(contentsOf: recovery).contains(Data(repeating: 0x43, count: 32)))
    }
}

private final class BackupTestKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: Data] = [:]
    private var readCount = 0
    var count: Int { lock.withLock { values.count } }
    var reads: Int { lock.withLock { readCount } }
    var access: ArchiveBackupKeys {
        .init(lookup: { [self] id in lock.withLock { readCount += 1; return values[id] } }, install: { [self] id, key in
            try lock.withLock {
                guard key.count == 32, values[id] == nil || values[id] == key else { throw ArchiveBackupError.conflict }
                values[id] = key
            }
        })
    }
}

private actor BackupTestStorage: ArchiveBackupObjectStorage {
    nonisolated let storageID: String
    private var objects: [String: Data] = [:]
    private(set) var puts = 0
    private let beforePut: (@Sendable () throws -> Void)?
    init(_ name: String, beforePut: (@Sendable () throws -> Void)? = nil) {
        storageID = ArchiveBackupCryptography.hash(Data(name.utf8)); self.beforePut = beforePut
    }
    func seed(key: String, data: Data) { objects[key] = data }
    func head(key: String) -> S3ObjectReceipt? {
        objects[key].map { .init(key: key, byteCount: Int64($0.count), sha256: ArchiveBackupCryptography.hash($0)) }
    }
    func download(key: String, to destination: URL, sha256: String, byteCount: Int64) throws {
        guard let data = objects[key], Int64(data.count) == byteCount, ArchiveBackupCryptography.hash(data) == sha256 else { throw S3ObjectStoreError.integrity }
        try data.write(to: destination, options: .withoutOverwriting)
    }
    func put(file: URL, key: String, sha256: String, byteCount: Int64) throws -> S3ObjectReceipt {
        puts += 1
        try beforePut?()
        let data = try Data(contentsOf: file)
        guard Int64(data.count) == byteCount, ArchiveBackupCryptography.hash(data) == sha256 else { throw S3ObjectStoreError.integrity }
        if let existing = objects[key], existing != data { throw S3ObjectStoreError.conflict }
        objects[key] = data; return .init(key: key, byteCount: byteCount, sha256: sha256)
    }
}
private enum BackupTestFailure: Error { case refused }

private actor BackupPolicySwitch {
    private var calls = 0
    func next() -> Bool? { calls += 1; return calls < 3 }
}
private actor BackupPolicyCancellation {
    private var calls = 0
    func next() -> Bool? {
        calls += 1
        if calls == 2 { withUnsafeCurrentTask { $0?.cancel() } }
        return true
    }
}
