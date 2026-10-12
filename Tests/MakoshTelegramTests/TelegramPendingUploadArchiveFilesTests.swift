import XCTest
import Foundation
import CryptoKit
import MakoshCore
@testable import MakoshTelegram

@MainActor final class TelegramPendingUploadArchiveFilesTests: TelegramSourceFactsIntegrationTestCase {
    // Catches storing the ZIP under a source/prepared identity or depending on deleted stages during reopen.
    func testStoredArchiveRestoresExactZIPAfterStagesAreDeletedAcrossRepositoryRestart() async throws {
        let fixture = try await sourceFactsArchive()
        try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
        let bundle = try await bundle(fixture)
        defer { discard(bundle) }
        let bytes = try Data(contentsOf: bundle.archive.file.url), id = UUID(), preparation = UUID()
        guard let capture = acceptedCapture(bundle.archive.file) else { return }
        guard let record = await accepted({ try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(bundle.archive,
            sources: bundle.sources, archiveID: id, accountID: 1, chatID: 42, preparationID: preparation, capture: capture) }) else { return }
        XCTAssertEqual(record.state, .stored)
        XCTAssertEqual(record.identity, identity(preparation))
        XCTAssertEqual(record.attachment.id, "archive:" + id.uuidString.lowercased())
        XCTAssertEqual(record.attachment.kind, "file"); XCTAssertEqual(record.attachment.name, "Telegram Archive.zip")
        XCTAssertEqual(record.attachment.size, Int64(bytes.count))
        XCTAssertEqual(record.plaintextByteCount, Int64(bytes.count)); XCTAssertEqual(record.plaintextSHA256, digest(bytes))
        XCTAssertNotEqual(id, bundle.archive.file.id)
        XCTAssertEqual(try eventCount(fixture), 2)
        discard(bundle)
        let repository = try reopenedRepository(fixture)
        guard let restored = await accepted({ try await TelegramPendingUploadFiles(repository: repository).restoreArchive(record: record,
            archiveID: id, accountID: 1, chatID: 42, preparationID: preparation) }) else { return }
        defer { try? TelegramUploadFileIO.discard(restored) }
        XCTAssertNotEqual(restored.id, bundle.archive.file.id); XCTAssertNotEqual(restored.id, id)
        XCTAssertEqual(restored.name, "Telegram Archive.zip"); XCTAssertEqual(restored.mode, .file)
        XCTAssertNil(restored.metadata); XCTAssertNil(restored.video); XCTAssertNil(restored.videoCover)
        XCTAssertNil(restored.pixelWidth); XCTAssertNil(restored.pixelHeight)
        XCTAssertEqual(try Data(contentsOf: restored.url), bytes)
        let remote = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
        XCTAssertNotNil(remote)
    }

    // Catches routing disabled preparation to S3 or promoting its local record after enable/resume.
    func testDisabledArchiveReopensLocallyAndNeverPromotesAfterPolicyEnable() async throws {
        let fixture = try await sourceFactsArchive(), bundle = try await bundle(fixture)
        defer { discard(bundle) }
        let bytes = try Data(contentsOf: bundle.archive.file.url), id = bundle.archive.file.id, preparation = UUID()
        guard let record = await accepted({ try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(bundle.archive,
            sources: bundle.sources, archiveID: id, accountID: 1, chatID: 42, preparationID: preparation) }) else { return }
        XCTAssertEqual(record.state, .local)
        XCTAssertEqual(record.purpose, .outgoing(defaultEnabled: true))
        XCTAssertEqual(try eventCount(fixture), 0)
        XCTAssertEqual(try fixture.localRecords(), [record.id.uuidString.lowercased() + ".local"])
        let absent = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
        XCTAssertNil(absent)
        discard(bundle)
        let repository = try reopenedRepository(fixture)
        guard let restored = await accepted({ try await TelegramPendingUploadFiles(repository: repository).restoreArchive(record: record,
            archiveID: id, accountID: 1, chatID: 42, preparationID: preparation) }) else { return }
        defer { try? TelegramUploadFileIO.discard(restored) }
        XCTAssertNotEqual(restored.id, id)
        XCTAssertEqual(try Data(contentsOf: restored.url), bytes)
        try await repository.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
        let resumed = try await repository.resume()
        XCTAssertEqual(resumed, 0)
        XCTAssertEqual(try eventCount(fixture), 0)
        XCTAssertEqual(try fixture.localRecords(), [record.id.uuidString.lowercased() + ".local"])
        let stillAbsent = try await S3ObjectStore(configuration: fixture.configuration).head(key: record.objectKey)
        XCTAssertNil(stillAbsent)
        guard let again = await accepted({ try await TelegramPendingUploadFiles(repository: repository).restoreArchive(record: record,
            archiveID: id, accountID: 1, chatID: 42, preparationID: preparation) }) else { return }
        defer { try? TelegramUploadFileIO.discard(again) }
        XCTAssertEqual(try Data(contentsOf: again.url), bytes)
    }

    // Catches ignoring an authenticated member digest while saving otherwise valid ZIP bytes.
    func testForgedMemberIsRefusedBeforeAnyLocalOrS3Copy() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive()
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let bundle = try await bundle(fixture)
            defer { discard(bundle) }
            let member = bundle.archive.members[1]
            let forged = TelegramUploadArchiveIO.Member(itemID: member.itemID, sourceName: member.sourceName,
                entryName: member.entryName, byteCount: member.byteCount, plaintextSHA256: String(repeating: "0", count: 64))
            let archive = TelegramUploadArchiveIO.Archive(file: bundle.archive.file, members: [bundle.archive.members[0], forged])
            await refused { _ = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(archive,
                sources: bundle.sources, archiveID: UUID(), accountID: 1, chatID: 42, preparationID: UUID()) }
            try noCopies(fixture)
        }
    }

    // Catches accepting tampered ZIP headers or newer raw originals before the first immutable write.
    func testTamperedZIPAndSameLengthRawSourceAreRefusedBeforeAnyCopy() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive()
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let first = try await bundle(fixture)
            defer { discard(first) }
            var badZIP = try Data(contentsOf: first.archive.file.url); badZIP[0] ^= 1
            try badZIP.write(to: first.archive.file.url)
            await refused { _ = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(first.archive,
                sources: first.sources, archiveID: UUID(), accountID: 1, chatID: 42, preparationID: UUID()) }
            let second = try await bundle(fixture)
            defer { discard(second) }
            var changed = try Data(contentsOf: second.sources[0].file.url); changed[0] ^= 1
            try changed.write(to: second.sources[0].file.url)
            await refused { _ = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(second.archive,
                sources: second.sources, archiveID: UUID(), accountID: 1, chatID: 42, preparationID: UUID()) }
            try noCopies(fixture)
        }
    }

    // Catches checking only the post-upload receipt when an unrelated held capture has the same count.
    func testUnrelatedSameLengthCaptureIsRefusedBeforeAnyImmutableRecord() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive()
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let bundle = try await bundle(fixture)
            defer { discard(bundle) }
            let wrong = fixture.root.appendingPathComponent("wrong-capture-" + UUID().uuidString)
            try Data(repeating: 0x5a, count: Int(bundle.archive.file.size)).write(to: wrong)
            let capture = try ArchiveFileCapture(file: wrong, byteCount: bundle.archive.file.size)
            await refused { _ = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(bundle.archive,
                sources: bundle.sources, archiveID: UUID(), accountID: 1, chatID: 42, preparationID: UUID(), capture: capture) }
            try noCopies(fixture)
        }
    }

    // Catches treating an output stage ID as the durable archive identity or admitting zero/overlapping send IDs.
    func testStableArchiveIdentityMustBeNonzeroAndDisjointBeforeAnyCopy() async throws {
        let fixture = try await sourceFactsArchive(), bundle = try await bundle(fixture)
        defer { discard(bundle) }
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        for id in [zero, bundle.sources[0].itemID, bundle.sources[0].file.id] {
            await refused { _ = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(bundle.archive,
                sources: bundle.sources, archiveID: id, accountID: 1, chatID: 42, preparationID: UUID()) }
        }
        await refused { _ = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(bundle.archive,
            sources: bundle.sources, archiveID: UUID(), accountID: 1, chatID: 42, preparationID: zero) }
        try noCopies(fixture)
    }

    // Catches accepting an authenticated received/conversation record as a new outgoing archive preparation.
    func testRestoreRefusesAuthenticatedConversationPurpose() async throws {
        let fixture = try await sourceFactsArchive()
        try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: true)
        let bundle = try await bundle(fixture)
        defer { discard(bundle) }
        let id = UUID(), preparation = UUID()
        let captured = try await fixture.archive.captureConversationFile(
            ArchiveFileCapture(file: bundle.archive.file.url, byteCount: bundle.archive.file.size),
            identity: identity(preparation), attachment: .init(id: "archive:" + id.uuidString.lowercased(),
                kind: "file", name: "Telegram Archive.zip", size: bundle.archive.file.size), defaultEnabled: true)
        let record = try XCTUnwrap(captured)
        XCTAssertEqual(record.purpose, .conversation(defaultEnabled: true))
        let events = try eventCount(fixture)
        await refused { _ = try await TelegramPendingUploadFiles(repository: fixture.archive).restoreArchive(record: record,
            archiveID: id, accountID: 1, chatID: 42, preparationID: preparation) }
        XCTAssertEqual(try eventCount(fixture), events)
        let originals = try Data(contentsOf: bundle.archive.file.url)
        XCTAssertFalse(originals.isEmpty)
    }

    // Catches supplied-capture bypass of the fixed plain ZIP representation, including recorded provenance.
    func testTypedRecordedAndNonplainZIPRepresentationsAreRefusedBeforeAnyCopy() async throws {
        let fixture = try await sourceFactsArchive(), bundle = try await bundle(fixture)
        defer { discard(bundle) }
        let file = bundle.archive.file
        let roundJSON: [String: Any] = ["kind": "roundVideo", "payload": ["nativeDuration": 2,
            "plaintextSHA256": String(repeating: "a", count: 64), "isOneTime": false]]
        let round = try JSONDecoder().decode(TelegramUploadMetadata.self, from: JSONSerialization.data(withJSONObject: roundJSON))
        let variants = [
            replacing(file, name: "different.zip"), replacing(file, mode: .photo), replacing(file, mode: .video),
            replacing(file, width: 40), replacing(file, height: 40),
            replacing(file, metadata: .webP(.init(width: 320, height: 160))),
            replacing(file, metadata: .voice(.init(sampleCount: 48_001, plaintextSHA256: String(repeating: "a", count: 64)))),
            replacing(file, metadata: round),
        ]
        for invalid in variants {
            XCTAssertThrowsError(try TelegramPendingUploadFiles.captureArchive(invalid))
            guard let frozen = acceptedCapture(file) else { return }
            await refused { _ = try await TelegramPendingUploadFiles(repository: fixture.archive).saveArchive(
                .init(file: invalid, members: bundle.archive.members), sources: bundle.sources, archiveID: UUID(),
                accountID: 1, chatID: 42, preparationID: UUID(), capture: frozen) }
        }
        try noCopies(fixture)
    }

    // Catches restoring a foreign scope/identity or trusting altered durable record metadata at export.
    func testRestoreRefusesForeignScopeInvalidProfileAndUnauthenticatedMetadata() async throws {
        for enabled in [false, true] {
            let fixture = try await sourceFactsArchive()
            try await fixture.archive.setConversationFileSavingEnabled(identity: fixture.identity, enabled: enabled)
            let bundle = try await bundle(fixture)
            defer { discard(bundle) }
            let id = UUID(), preparation = UUID(), adapter = TelegramPendingUploadFiles(repository: fixture.archive)
            guard let record = await accepted({ try await adapter.saveArchive(bundle.archive, sources: bundle.sources, archiveID: id,
                accountID: 1, chatID: 42, preparationID: preparation) }) else { return }
            let events = try eventCount(fixture), queue = try queueEntries(fixture)
            for scope in [(Int64(2), Int64(42), preparation, id), (1, 43, preparation, id), (1, 42, UUID(), id), (1, 42, preparation, UUID())] {
                await refused { _ = try await adapter.restoreArchive(record: record, archiveID: scope.3,
                    accountID: scope.0, chatID: scope.1, preparationID: scope.2) }
            }
            let variants = [
                try altered(record) { $0["state"] = "pending" },
                try altered(record) { var a = $0["attachment"] as! [String: Any]; a["kind"] = "photo"; $0["attachment"] = a },
                try altered(record) { var a = $0["attachment"] as! [String: Any]; a["name"] = "other.zip"; $0["attachment"] = a },
                try altered(record) { $0["plaintextSHA256"] = String(repeating: "0", count: 64) },
                try altered(record) { $0["capturedAt"] = ($0["capturedAt"] as! Double) + 1 },
                try altered(record) { $0["plaintextByteCount"] = 21; var a = $0["attachment"] as! [String: Any]; a["size"] = 21; $0["attachment"] = a },
            ]
            for forged in variants {
                await refused { _ = try await adapter.restoreArchive(record: forged, archiveID: id,
                    accountID: 1, chatID: 42, preparationID: preparation) }
            }
            XCTAssertEqual(try eventCount(fixture), events); XCTAssertEqual(try queueEntries(fixture), queue)
            guard let restored = await accepted({ try await adapter.restoreArchive(record: record, archiveID: id, accountID: 1, chatID: 42, preparationID: preparation) }) else { return }
            defer { try? TelegramUploadFileIO.discard(restored) }
            XCTAssertEqual(try Data(contentsOf: restored.url), try Data(contentsOf: bundle.archive.file.url))
        }
    }

    // Catches a cancelled caller creating an immutable archive record before cancellation is checked.
    func testPreCancelledSaveAndRestoreKeepExistingRecordsUnchanged() async throws {
        let fixture = try await sourceFactsArchive(), bundle = try await bundle(fixture)
        defer { discard(bundle) }
        let id = UUID(), preparation = UUID(), adapter = TelegramPendingUploadFiles(repository: fixture.archive)
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.saveArchive(bundle.archive, sources: bundle.sources, archiveID: id,
                accountID: 1, chatID: 42, preparationID: preparation)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled save published an archive") }
        catch { XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)") }
        try noCopies(fixture)
        guard let record = await accepted({ try await adapter.saveArchive(bundle.archive, sources: bundle.sources, archiveID: id,
            accountID: 1, chatID: 42, preparationID: preparation) }) else { return }
        let queue = try queueEntries(fixture)
        let restoring = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.restoreArchive(record: record, archiveID: id, accountID: 1, chatID: 42, preparationID: preparation)
        }
        do { let unexpected = try await restoring.value; try? TelegramUploadFileIO.discard(unexpected); XCTFail("Cancelled restore published a stage") }
        catch { XCTAssertTrue(error is CancellationError, "Expected cancellation, got \(error)") }
        XCTAssertEqual(try eventCount(fixture), 0); XCTAssertEqual(try queueEntries(fixture), queue)
    }

    private struct Bundle {
        let sources: [TelegramUploadArchiveIO.Source]
        let archive: TelegramUploadArchiveIO.Archive
    }
    private func bundle(_ fixture: SourceFactsTestArchive) async throws -> Bundle {
        var sources: [TelegramUploadArchiveIO.Source] = []
        do {
            for (name, bytes) in [(".hidden", Data("first source\n".utf8)), ("second.bin", Data([0, 255, 17]))] {
                let url = fixture.root.appendingPathComponent(UUID().uuidString)
                try bytes.write(to: url)
                let raw = try await TelegramUploadFileIO.stage(url, mode: .file)
                try FileManager.default.removeItem(at: url)
                let file = replacing(raw, name: name)
                sources.append(.init(itemID: UUID(), file: file))
            }
            return Bundle(sources: sources, archive: try await TelegramUploadArchiveIO.prepare(sources))
        } catch { sources.forEach { try? TelegramUploadFileIO.discard($0.file) }; throw error }
    }
    private func discard(_ bundle: Bundle) {
        bundle.sources.forEach { try? TelegramUploadFileIO.discard($0.file) }
        try? TelegramUploadFileIO.discard(bundle.archive.file)
    }
    private func replacing(_ file: TelegramUploadFile, name: String? = nil, mode: TelegramUploadMode? = nil,
        width: Int32? = nil, height: Int32? = nil, metadata: TelegramUploadMetadata? = nil) -> TelegramUploadFile {
        .init(id: file.id, name: name ?? file.name, size: file.size, mode: mode ?? file.mode,
            pixelWidth: width, pixelHeight: height, url: file.url, directory: file.directory, metadata: metadata)
    }
    private func identity(_ preparation: UUID) -> MessageArchiveIdentity {
        .init(service: "telegram", accountID: "1", conversationID: "42", messageID: "pending-upload:" + preparation.uuidString.lowercased())
    }
    private func reopenedRepository(_ fixture: SourceFactsTestArchive) throws -> ArchiveFileRepository {
        try ArchiveFileRepository(connectionString: fixture.database.connectionString, schema: fixture.database.schema,
            configuration: fixture.configuration, spoolDirectory: fixture.root.appendingPathComponent("queue"),
            keyProvider: { _, _ in Data(repeating: 0x59, count: 32) })
    }
    private func eventCount(_ fixture: SourceFactsTestArchive) throws -> Int {
        let rows = try fixture.database.execute("SELECT count(*) FROM \"\(fixture.database.schema)\".archive_file_events")
        return try XCTUnwrap(rows.first?.first.flatMap(Int.init))
    }
    private func queueEntries(_ fixture: SourceFactsTestArchive) throws -> [String] {
        let directory = fixture.root.appendingPathComponent("queue")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
    private func noCopies(_ fixture: SourceFactsTestArchive, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try eventCount(fixture), 0, file: file, line: line)
        XCTAssertEqual(try queueEntries(fixture), [], file: file, line: line)
    }
    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    private func altered(_ record: ArchiveFileRecord, _ change: (inout [String: Any]) -> Void) throws -> ArchiveFileRecord {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        change(&value)
        return try JSONDecoder().decode(ArchiveFileRecord.self, from: JSONSerialization.data(withJSONObject: value))
    }
    private func acceptedCapture(_ file: TelegramUploadFile, filePath: StaticString = #filePath, line: UInt = #line) -> ArchiveFileCapture? {
        do { return try TelegramPendingUploadFiles.captureArchive(file) }
        catch { XCTFail("Valid plain ZIP capture was refused: \(error)", file: filePath, line: line); return nil }
    }
    private func accepted<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async -> T? {
        do { return try await operation() }
        catch { XCTFail("Valid archive operation was refused: \(error)", file: file, line: line); return nil }
    }
    private func refused(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Invalid archive boundary admitted", file: file, line: line) }
        catch { }
    }
}
