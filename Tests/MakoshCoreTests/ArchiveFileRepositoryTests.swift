import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import MakoshCore

final class ArchiveFileRepositoryTests: XCTestCase {
    private let key = Data(repeating: 0x73,count: 32)
    private let identity = MessageArchiveIdentity(service: "telegram",accountID: "synthetic-account",conversationID: "chat",messageID: "0:1")
    private let attachment = MessageArchiveAttachment(id: "synthetic-file",kind: "file",name: "synthetic-private-name.txt",size: nil)
    private func database() throws -> PostgresTestDatabase {
        let db = try PostgresTestDatabase(); addTeardownBlock { try db.cleanup() }; return db
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: false,attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: root) }; return root
    }
    private func config() throws -> S3ObjectStoreConfiguration {
        guard let path = ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"] else { throw XCTSkip("S3 integration requires explicit synthetic development configuration") }
        return try S3ConfigurationFile.read(URL(fileURLWithPath: path))
    }
    private func repository(_ db: PostgresTestDatabase,_ root: URL,_ config: S3ObjectStoreConfiguration) throws -> ArchiveFileRepository {
        let key = key
        return try ArchiveFileRepository(connectionString: db.connectionString,schema: db.schema,configuration: config,spoolDirectory: root.appendingPathComponent("queue"),keyProvider: { _,_ in key })
    }

    func testReadOnlyMutationAdmissionRefusesBeforeKeyAccessOrSpoolCreation() async throws {
        let config = try config(), db = try database(), root = try directory(), key = key
        _ = try MessageArchiveStore(connectionString: db.connectionString,schema: db.schema) { _,_ in key }
        let source = root.appendingPathComponent("source")
        let bytes = Data("synthetic read-only admission".utf8)
        try bytes.write(to: source)
        let capture = try ArchiveFileCapture(file: source,byteCount: Int64(bytes.count))
        for operation in 0..<7 {
            let queue = root.appendingPathComponent("readonly-\(operation)")
            let read = try ArchiveFileRepository(connectionString: db.connectionString,schema: db.schema,
                configuration: config,spoolDirectory: queue,readOnly: true,keyProvider: { _,_ in
                    XCTFail("Mutation admission must precede key access")
                    return key
                })
            do {
                switch operation {
                case 0: _ = try await read.capture(capture,identity: identity,attachment: attachment)
                case 1: _ = try await read.capture(capture,identity: identity,attachment: attachment,defaultEnabled: false)
                case 2: _ = try await read.captureConversationFile(capture,identity: identity,attachment: attachment,defaultEnabled: true)
                case 3: _ = try await read.captureConversationFile(capture,identity: identity,attachment: attachment,defaultEnabled: false)
                case 4: _ = try await read.resume()
                case 5: _ = try await read.recoverOutgoingCapture(id: UUID(),identity: identity,attachmentID: attachment.id)
                default: try await read.setConversationFileSavingEnabled(identity: identity,enabled: false)
                }
                XCTFail("Read-only mutation must be rejected: \(operation)")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: queue.path),"Admission must not create a spool")
        }
    }

    func testReadOnlyPendingReplayDoesNotCreateS3ObjectsOrRemoveQueueAndStillExports() async throws {
        let config = try config(), db = try database(), root = try directory(), key = key
        let store = try MessageArchiveStore(connectionString: db.connectionString,schema: db.schema) { _,_ in key }
        let vault = try store.fileVault(), id = UUID(), queue = root.appendingPathComponent("queue")
        try FileManager.default.createDirectory(at: queue,withIntermediateDirectories: false,attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("source"), bytes = Data("synthetic authenticated pending replay".utf8)
        try bytes.write(to: source)
        let encrypted = queue.appendingPathComponent(id.uuidString.lowercased() + ".envelope")
        let receipt = try ArchiveFileCapture(file: source,byteCount: Int64(bytes.count)).seal(to: encrypted,key: vault.key,objectID: id)
        let storageID = S3Signer.hex(SHA256.hash(data: Data((config.endpoint + "\u{0}" + config.region + "\u{0}" + config.bucket).utf8)))
        let pending = ArchiveFileRecord(id: id,identity: identity,attachment: attachment,
            objectKey: "vaults/\(vault.id.uuidString.lowercased())/files/\(id.uuidString.lowercased())",
            storageID: storageID,receipt: receipt,state: .pending,purpose: .outgoing(defaultEnabled: true))
        XCTAssertTrue(try store.appendFile(pending))
        let sealed = try XCTUnwrap(AES.GCM.seal(JSONEncoder().encode(pending),using: SymmetricKey(data: vault.key),
            authenticating: Data("makosh-file-queue-v1|\(vault.id.uuidString)|\(id.uuidString)".utf8)).combined)
        let manifest = queue.appendingPathComponent(id.uuidString.lowercased() + ".receipt")
        try sealed.write(to: manifest,options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath: manifest.path)
        let envelopeBytes = try Data(contentsOf: encrypted), storage = try S3ObjectStore(configuration: config)
        let absent = try await storage.head(key: pending.objectKey); XCTAssertNil(absent)
        let read = try ArchiveFileRepository(connectionString: db.connectionString,schema: db.schema,
            configuration: config,spoolDirectory: queue,readOnly: true,keyProvider: { _,create in
                XCTAssertFalse(create); return key
            })
        // A matching pending row takes appendFile's idempotent SELECT-only path.
        let readStore = try MessageArchiveStore(connectionString: db.connectionString,schema: db.schema,readOnly: true) { _,_ in key }
        XCTAssertFalse(try readStore.appendFile(pending))
        do { _ = try await read.resume(); XCTFail("Read-only replay must refuse") } catch {}
        let afterResume = try await storage.head(key: pending.objectKey); XCTAssertNil(afterResume,"Read-only replay must perform zero PUTs")
        do { _ = try await read.recoverOutgoingCapture(id: id,identity: identity,attachmentID: attachment.id); XCTFail("Read-only recovery must refuse") } catch {}
        let afterRecovery = try await storage.head(key: pending.objectKey); XCTAssertNil(afterRecovery)
        XCTAssertEqual(try Data(contentsOf: encrypted),envelopeBytes)
        XCTAssertEqual(try Data(contentsOf: manifest),sealed)
        XCTAssertEqual(try db.execute("SELECT state FROM \"\(db.schema)\".archive_file_events"),[["pending"]])

        let writable = try repository(db,root,config)
        let resumed = try await writable.resume(); XCTAssertEqual(resumed,1)
        let records = try await read.files(identity: identity,attachmentID: attachment.id)
        let stored = try XCTUnwrap(records.first); XCTAssertEqual(records.count,1)
        let exported = root.appendingPathComponent("explicit-export")
        try await read.export(stored,to: exported); XCTAssertEqual(try Data(contentsOf: exported),bytes)

        // Both receipts already exist: replay must also leave retained spool material alone.
        try envelopeBytes.write(to: encrypted,options: .withoutOverwriting)
        try sealed.write(to: manifest,options: .withoutOverwriting)
        for file in [encrypted,manifest] { try FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath: file.path) }
        do { _ = try await read.resume(); XCTFail("Read-only stored replay must refuse") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: encrypted.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
    }

    func testFrozenCaptureSurvivesCacheRemovalAndReopensFromS3WithMetadataOnlyInPostgres() async throws {
        let config = try config(), db = try database(), root = try directory()
        let bytes = Data("SYNTHETIC_PRIVATE_FILE_BYTES_\(UUID().uuidString)".utf8)
        let source = root.appendingPathComponent("telegram-cache")
        try bytes.write(to: source)
        let capture = try ArchiveFileCapture(file: source,byteCount: Int64(bytes.count))
        try FileManager.default.removeItem(at: source)
        let record = try await repository(db,root,config).capture(capture,identity: identity,attachment: attachment)
        XCTAssertEqual(record.state,.stored)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("queue").path).isEmpty)
        let reopened = try repository(db,root,config)
        let records = try await reopened.files(identity: identity,attachmentID: attachment.id)
        XCTAssertEqual(records,[record])
        let exported = root.appendingPathComponent("restored")
        try await reopened.export(record,to: exported)
        XCTAssertEqual(try Data(contentsOf: exported),bytes)
        do { try await reopened.export(record,to: exported); XCTFail("Existing export must survive") } catch {}
        XCTAssertEqual(try Data(contentsOf: exported),bytes)
        let rows = try db.execute("SELECT state,ciphertext,attachment_token FROM \"\(db.schema)\".archive_file_events")
        XCTAssertEqual(rows.count,2)
        XCTAssertFalse(rows.joined().joined().contains(attachment.name))
        XCTAssertFalse(rows.joined().joined().contains(String(decoding: bytes,as: UTF8.self)))
        let columns = try db.execute("SELECT data_type FROM information_schema.columns WHERE table_schema='\(db.schema)' AND table_name='archive_file_events'")
        XCTAssertFalse(columns.joined().contains("bytea"))
        for statement in ["UPDATE \"\(db.schema)\".archive_file_events SET state='stored'", "DELETE FROM \"\(db.schema)\".archive_file_events", "TRUNCATE \"\(db.schema)\".archive_file_events"] {
            XCTAssertThrowsError(try db.execute(statement))
        }
        let other = MessageArchiveIdentity(service: "telegram",accountID: "other-account",conversationID: "chat",messageID: "0:1")
        let otherRecords = try await reopened.files(identity: other,attachmentID: attachment.id)
        XCTAssertTrue(otherRecords.isEmpty)
    }

    func testS3SuccessThenPostgresFailureLeavesEncryptedQueueAndRestartReconcilesSameObject() async throws {
        let config = try config(), db = try database(), root = try directory()
        _ = try MessageArchiveStore(connectionString: db.connectionString,schema: db.schema) { _,_ in self.key }
        try db.execute("CREATE FUNCTION \"\(db.schema)\".reject_stored() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.state='stored' THEN RAISE EXCEPTION 'synthetic stored failure'; END IF; RETURN NEW; END $$")
        try db.execute("CREATE TRIGGER reject_stored BEFORE INSERT ON \"\(db.schema)\".archive_file_events FOR EACH ROW EXECUTE FUNCTION \"\(db.schema)\".reject_stored()")
        let source = root.appendingPathComponent("source"), bytes = Data(repeating: 0x61,count: 1024 * 1024 + 11)
        try bytes.write(to: source)
        let first = try repository(db,root,config)
        do { _ = try await first.capture(ArchiveFileCapture(file: source,byteCount: Int64(bytes.count)),identity: identity,attachment: attachment); XCTFail("Expected stored-receipt rollback") } catch {}
        try FileManager.default.removeItem(at: source)
        let queue = root.appendingPathComponent("queue")
        let pending = try FileManager.default.contentsOfDirectory(at: queue,includingPropertiesForKeys: nil)
        XCTAssertEqual(pending.filter { $0.pathExtension == "receipt" }.count,1)
        XCTAssertEqual(pending.filter { $0.pathExtension == "envelope" }.count,1)
        XCTAssertEqual(try db.execute("SELECT state FROM \"\(db.schema)\".archive_file_events"),[["pending"]])
        for url in pending {
            let data = try Data(contentsOf: url)
            XCTAssertNil(data.range(of: Data(attachment.name.utf8)))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        }
        // Interrupted unpublished receipt and one corrupt published item cannot block valid recovery.
        try Data([1,2,3]).write(to: queue.appendingPathComponent("unfinished.preparing"))
        let corrupt = queue.appendingPathComponent("00000000-0000-0000-0000-000000000000.receipt")
        try Data([1,2,3]).write(to: corrupt,options: .withoutOverwriting)
        try db.execute("DROP TRIGGER reject_stored ON \"\(db.schema)\".archive_file_events")
        let reopened = try repository(db,root,config)
        do { _ = try await reopened.resume(); XCTFail("Corrupt receipt must be reported") } catch {}
        let records = try await reopened.files(identity: identity,attachmentID: attachment.id)
        XCTAssertEqual(records.count,1)
        XCTAssertEqual(try db.execute("SELECT count(DISTINCT object),count(*) FROM \"\(db.schema)\".archive_file_events"),[["1","2"]])
        let restored = root.appendingPathComponent("restored")
        try await reopened.export(try XCTUnwrap(records.first),to: restored)
        XCTAssertEqual(try Data(contentsOf: restored),bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: corrupt.path))
        try FileManager.default.removeItem(at: corrupt)
        let resumed = try await reopened.resume(); XCTAssertEqual(resumed,0)
    }

    func testPublishedReceiptIsQueuedWhenDirectorySyncFailsAndRestartUsesSameObject() async throws {
        let config = try config(), db = try database(), root = try directory(), key = key
        let queue = root.appendingPathComponent("queue"), source = root.appendingPathComponent("cache")
        let bytes = Data("SYNTHETIC_DIRECTORY_SYNC_FAILURE".utf8)
        try bytes.write(to: source)
        let first = try ArchiveFileRepository(connectionString: db.connectionString,schema: db.schema,
            configuration: config,spoolDirectory: queue,keyProvider: { _,_ in key },
            directorySync: { _ in throw MessageArchiveError.database })
        do {
            _ = try await first.capture(ArchiveFileCapture(file: source,byteCount: Int64(bytes.count)),identity: identity,attachment: attachment)
            XCTFail("Expected queue-directory sync failure")
        } catch let failure as ArchiveFileCaptureFailure {
            XCTAssertTrue(failure.isQueued,"Published receipt must be reconciled, not recaptured")
        }
        try FileManager.default.removeItem(at: source)
        let receipts = try FileManager.default.contentsOfDirectory(at: queue,includingPropertiesForKeys: nil).filter { $0.pathExtension == "receipt" }
        XCTAssertEqual(receipts.count,1)
        let expectedID = UUID(uuidString: try XCTUnwrap(receipts.first).deletingPathExtension().lastPathComponent)
        let reopened = try repository(db,root,config)
        let count = try await reopened.resume(); XCTAssertEqual(count,1)
        let records = try await reopened.files(identity: identity,attachmentID: attachment.id)
        XCTAssertEqual(records.map(\.id),[try XCTUnwrap(expectedID)])
        XCTAssertEqual(try db.execute("SELECT count(DISTINCT object),count(*) FROM \"\(db.schema)\".archive_file_events"),[["1","2"]])
        let restored = root.appendingPathComponent("restored")
        try await reopened.export(try XCTUnwrap(records.first),to: restored)
        XCTAssertEqual(try Data(contentsOf: restored),bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty)
    }

    func testConfigurationReaderRejectsPermissiveSymlinkFIFOAndMalformedFiles() throws {
        let root = try directory(), file = root.appendingPathComponent("config")
        let configuration = try S3ObjectStoreConfiguration(endpoint: "http://127.0.0.1:19399",region: "us-east-1",bucket: "synthetic-bucket",accessKeyID: "synthetic",secretAccessKey: "synthetic")
        try JSONEncoder().encode(configuration).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath: file.path)
        _ = try S3ConfigurationFile.read(file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644],ofItemAtPath: file.path)
        XCTAssertThrowsError(try S3ConfigurationFile.read(file))
        let link = root.appendingPathComponent("link"), fifo = root.appendingPathComponent("fifo")
        try FileManager.default.createSymbolicLink(at: link,withDestinationURL: file)
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        for path in [link,fifo,root] { XCTAssertThrowsError(try S3ConfigurationFile.read(path)) }
        try Data("private-invalid-json".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],ofItemAtPath: file.path)
        XCTAssertThrowsError(try S3ConfigurationFile.read(file)) { XCTAssertFalse($0.localizedDescription.contains("private-invalid")) }
    }
}
