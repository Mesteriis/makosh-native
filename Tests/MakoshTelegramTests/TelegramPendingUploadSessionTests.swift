import XCTest
import SwiftSignalKit
import MakoshCore
@testable import MakoshTelegram

@MainActor private final class PendingSessionRepository: TelegramPendingUploadRepository {
    let accountID: Int64 = 1
    var value: TelegramPendingUploadDraft?
    var writes: [TelegramPendingUploadDraft] = []
    var holdNextWrite = false
    var held: (TelegramPendingUploadDraft, @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void)?
    init(_ value: TelegramPendingUploadDraft?) { self.value = value }
    func load(chatID: Int64, completion: @escaping @MainActor (Result<TelegramPendingUploadDraft?, TelegramPendingUploadPersistenceError>) -> Void) -> Disposable {
        completion(.success(value)); return EmptyDisposable
    }
    func save(_ draft: TelegramPendingUploadDraft, expectedRevision: UUID?,
              completion: @escaping @MainActor (Result<Void, TelegramPendingUploadPersistenceError>) -> Void) {
        writes.append(draft)
        if holdNextWrite { holdNextWrite = false; held = (draft, completion) }
        else { value = draft; completion(.success(())) }
    }
    func release() {
        guard let held else { return }
        self.held = nil; value = held.0; held.1(.success(()))
    }
}

@MainActor final class TelegramPendingUploadSessionTests: XCTestCase {
    func testCoveredVideoPrepareRetryAndRestoreUseAuthenticatedSeparateS3Objects() async throws {
        let database = try PendingFilesTestDatabase()
        addTeardownBlock { try database.cleanup() }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath: XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let archive = try ArchiveFileRepository(connectionString: database.connectionString, schema: database.schema,
            configuration: configuration, spoolDirectory: root.appendingPathComponent("queue"), keyProvider: { _, _ in Data(repeating: 0x49, count: 32) })
        let source = root.appendingPathComponent("portrait.mov"), image = root.appendingPathComponent("cover.jpg")
        try await writeUploadVideoFixture(source); try writeUploadVideoCoverFixture(image)
        let original = try await TelegramUploadFileIO.stage(source, mode: .video)
        let cover = try await TelegramUploadVideoCoverIO.stage(image, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
        defer { try? TelegramUploadFileIO.discard(original); try? TelegramUploadFileIO.discard(cover.imageFile) }
        let file = TelegramUploadFile(id: original.id, name: original.name, size: original.size, mode: .video,
            pixelWidth: original.pixelWidth, pixelHeight: original.pixelHeight, url: original.url, directory: original.directory,
            video: original.video, videoCover: cover)
        let repository = PendingSessionRepository(nil)
        let session = TelegramPendingUploadSession(repository: repository, files: { TelegramPendingUploadFiles(repository: archive) })
        let id = UUID(), target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic"), input = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Covered video 😀"))
        try await session.prepare(preparationID: id, file: file, target: target, captionInput: input, originalDraft: nil)
        let first = try XCTUnwrap(repository.value), saved = try XCTUnwrap(first.videoCover)
        XCTAssertEqual(first.schemaVersion, 5); XCTAssertEqual(saved.file.plaintextSHA256, cover.sha256)
        XCTAssertNotEqual(saved.file.objectKey, first.file.objectKey)
        try await session.prepare(preparationID: id, file: file, target: target, captionInput: input, originalDraft: nil)
        XCTAssertEqual(repository.value?.videoCover, saved, "Retry reuses the committed cover receipt")
        let dropped = TelegramUploadFile(id: original.id, name: original.name, size: original.size, mode: .video,
            pixelWidth: original.pixelWidth, pixelHeight: original.pixelHeight, url: original.url, directory: original.directory, video: original.video)
        do {
            try await session.prepare(preparationID: id, file: dropped, target: target, captionInput: input, originalDraft: nil)
            XCTFail("Retry cannot silently drop the admitted cover")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        let videoBytes = try Data(contentsOf: original.url), coverBytes = try Data(contentsOf: cover.url)
        try TelegramUploadFileIO.discard(file)
        let restored = try await session.restoreFile(draft: XCTUnwrap(repository.value))
        defer { try? TelegramUploadFileIO.discard(restored) }
        let restoredCover = try XCTUnwrap(restored.videoCover)
        XCTAssertEqual(try Data(contentsOf: restored.url), videoBytes)
        XCTAssertEqual(try Data(contentsOf: restoredCover.url), coverBytes)
        XCTAssertEqual(restoredCover.width, 40); XCTAssertEqual(restoredCover.height, 80)
        XCTAssertEqual(restoredCover.sha256, cover.sha256)
    }
    func testCoverSurvivesCaptionChangesAndTerminalMarkers() async throws {
        for terminal: TelegramPendingUploadDisposition in [.accepted(localMessageID: "receipt"), .cancelled] {
            let first = try pendingUploadVideoCoverFixture()
            let repository = PendingSessionRepository(first)
            let session = TelegramPendingUploadSession(repository: repository, files: { throw TelegramUploadFileError.unavailable })
            let edited = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Updated cover caption 😀"))
            try await session.save(preparationID: first.id, chatID: first.chatID, captionInput: edited,
                captionAboveMedia: true, mediaSpoiler: true, disposition: .prepared)
            try await session.save(preparationID: first.id, chatID: first.chatID, captionInput: edited,
                captionAboveMedia: true, mediaSpoiler: true, disposition: .submissionStarted)
            let reopened = TelegramPendingUploadSession(repository: repository, files: { throw TelegramUploadFileError.unavailable })
            try await reopened.save(preparationID: first.id, chatID: first.chatID, captionInput: edited,
                captionAboveMedia: true, mediaSpoiler: true, disposition: terminal)
            let loaded = try await reopened.load(chatID: first.chatID)
            XCTAssertEqual(loaded?.videoCover, first.videoCover)
            XCTAssertEqual(loaded?.video, first.video); XCTAssertEqual(loaded?.captionInput, edited)
            XCTAssertEqual(loaded?.disposition, terminal)
        }
    }
    func testVideoDescriptorSurvivesCaptionChangesSubmissionAndTerminalMarkers() async throws {
        for terminal: TelegramPendingUploadDisposition in [.accepted(localMessageID: "receipt"), .cancelled] {
            let first = try pendingUploadVideoFixture()
            let repository = PendingSessionRepository(first)
            let session = TelegramPendingUploadSession(repository: repository, files: { throw TelegramUploadFileError.unavailable })
            let edited = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "Updated video caption 😀"))
            try await session.save(preparationID: first.id, chatID: first.chatID, captionInput: edited,
                captionAboveMedia: true, mediaSpoiler: true, disposition: .prepared)
            try await session.save(preparationID: first.id, chatID: first.chatID, captionInput: edited,
                captionAboveMedia: true, mediaSpoiler: true, disposition: .submissionStarted)
            let reopened = TelegramPendingUploadSession(repository: repository, files: { throw TelegramUploadFileError.unavailable })
            try await reopened.save(preparationID: first.id, chatID: first.chatID, captionInput: edited,
                captionAboveMedia: true, mediaSpoiler: true, disposition: terminal)
            let loaded = try await reopened.load(chatID: first.chatID)
            XCTAssertEqual(loaded?.video, first.video)
            XCTAssertEqual(loaded?.captionInput, edited)
            XCTAssertEqual(loaded?.captionAboveMedia, true); XCTAssertEqual(loaded?.mediaSpoiler, true)
            XCTAssertEqual(loaded?.disposition, terminal)
            XCTAssertEqual(loaded?.file, first.file)
        }
    }
    func testSpoilerAndPlacementWritesSurviveSessionRecreationAndAcceptedMarker() async throws {
        let first = try pendingUploadMutating(pendingUploadFixture()) {
            var file = $0["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
            attachment["kind"] = "photo"; file["attachment"] = attachment; $0["file"] = file
        }
        let repository = PendingSessionRepository(first)
        let session = TelegramPendingUploadSession(repository: repository, files: { throw TelegramUploadFileError.unavailable })
        try await session.save(preparationID: first.id, chatID: first.chatID, captionInput: first.captionInput,
            captionAboveMedia: true, mediaSpoiler: true, disposition: .prepared)
        let reopened = TelegramPendingUploadSession(repository: repository, files: { throw TelegramUploadFileError.unavailable })
        let loaded = try await reopened.load(chatID: first.chatID)
        XCTAssertEqual(loaded?.captionAboveMedia, true)
        XCTAssertEqual(loaded?.mediaSpoiler, true)
        try await reopened.save(preparationID: first.id, chatID: first.chatID, captionInput: first.captionInput,
            captionAboveMedia: true, mediaSpoiler: true, disposition: .submissionStarted)
        try await reopened.save(preparationID: first.id, chatID: first.chatID, captionInput: first.captionInput,
            captionAboveMedia: true, mediaSpoiler: true, disposition: .accepted(localMessageID: "receipt"))
        XCTAssertEqual(repository.value?.captionAboveMedia, true)
        XCTAssertEqual(repository.value?.mediaSpoiler, true)
        XCTAssertEqual(repository.value?.originalDraft, first.originalDraft)
    }
    func testPendingWritesSerializeAcrossCallerCancellationAndTombstoneRejectsResurrection() async throws {
        let first = try pendingUploadFixture(), repository = PendingSessionRepository(nil)
        repository.value = first; repository.holdNextWrite = true
        let session = TelegramPendingUploadSession(repository: repository, files: { throw TelegramUploadFileError.unavailable })
        let sending = Task { try await session.save(preparationID: first.id, chatID: first.chatID,
            captionInput: first.captionInput, disposition: .submissionStarted) }
        for _ in 0..<100 where repository.held == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(repository.held)
        sending.cancel() // An already authorized store operation still completes on its bound repository.
        let cancelling = Task { try await session.save(preparationID: first.id, chatID: first.chatID,
            captionInput: first.captionInput, disposition: .cancelled) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(repository.writes.count, 1)
        repository.release()
        try await sending.value; try await cancelling.value
        XCTAssertEqual(repository.writes.map(\.disposition), [.submissionStarted, .cancelled])
        let retained = try await session.load(chatID: first.chatID)
        XCTAssertEqual(retained?.disposition, .cancelled)
        do {
            try await session.save(preparationID: first.id, chatID: first.chatID,
                captionInput: first.captionInput, disposition: .prepared)
            XCTFail("A cancelled preparation must not be resurrected")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        XCTAssertEqual(repository.writes.count, 2)
    }

    func testOtherActivePreparationAndForeignScopeNeverAccessFileStorage() async throws {
        let first = try pendingUploadFixture(), repository = PendingSessionRepository(nil)
        repository.value = first
        var storageCalls = 0
        let session = TelegramPendingUploadSession(repository: repository, files: {
            storageCalls += 1; throw TelegramUploadFileError.unavailable
        })
        let unused = TelegramUploadFile(id: UUID(), name: "synthetic.txt", size: first.file.plaintextByteCount,
            mode: .file, pixelWidth: nil, pixelHeight: nil,
            url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
        do {
            try await session.prepare(preparationID: UUID(), file: unused,
                target: .init(accountID: 1, chatID: 42, title: "Synthetic"),
                captionInput: first.captionInput, originalDraft: first.originalDraft)
            XCTFail("Existing active preparation must be recovered before replacement")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        do {
            _ = try await session.load(chatID: 99)
            XCTFail("Repository scope confusion must fail closed")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .incompatibleData) }
        XCTAssertEqual(storageCalls, 0); XCTAssertTrue(repository.writes.isEmpty)
        XCTAssertEqual(repository.value, first)
    }

    func testAcceptedIdentityCannotChangeAndUncertainCannotReturnToPrepared() async throws {
        let first = try pendingUploadFixture(disposition: .submissionStarted)
        let repository = PendingSessionRepository(first)
        let session = TelegramPendingUploadSession(repository: repository, files: { throw TelegramUploadFileError.unavailable })
        do {
            try await session.save(preparationID: first.id, chatID: first.chatID,
                captionInput: first.captionInput, disposition: .prepared)
            XCTFail("Unknown enqueue result must not be made resendable")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        try await session.save(preparationID: first.id, chatID: first.chatID,
            captionInput: first.captionInput, disposition: .accepted(localMessageID: "synthetic-local:1"))
        do {
            try await session.save(preparationID: first.id, chatID: first.chatID,
                captionInput: first.captionInput, disposition: .accepted(localMessageID: "synthetic-local:2"))
            XCTFail("One preparation cannot acknowledge a different local message")
        } catch let error as TelegramPendingUploadPersistenceError { XCTAssertEqual(error, .conflict) }
        try await session.save(preparationID: first.id, chatID: first.chatID,
            captionInput: first.captionInput, disposition: .accepted(localMessageID: "synthetic-local:1"))
        XCTAssertEqual(repository.value?.disposition, .accepted(localMessageID: "synthetic-local:1"))
    }
}
