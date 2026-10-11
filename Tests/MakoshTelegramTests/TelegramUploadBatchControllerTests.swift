import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import MakoshTelegram

@MainActor final class TelegramUploadBatchControllerTests: XCTestCase {
    func testOpusAndMP3AreOrdinaryGroupedMusicEvenWithMisleadingNames() async throws {
        let root = try makeSources()[0].deletingLastPathComponent()
        let opus = root.appendingPathComponent("opaque.bin"), mp3 = root.appendingPathComponent("music.mp3")
        try uploadOpusAudioFixture().write(to: opus); try writeUploadMP3AudioFixture(mp3)
        let controller = TelegramUploadController(); controller.bind(provider: BatchStagingProvider())
        defer { controller.clear() }
        controller.prepare(sources: [.init(source: opus, mode: .file), .init(source: mp3, mode: .file)],
            isGrouped: true, target: .init(accountID: 1, chatID: 42, title: "Synthetic music"), captionInput: .empty)
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready); XCTAssertEqual(controller.presentation, .file)
        XCTAssertTrue(controller.isGrouped); XCTAssertTrue(controller.canGroupItems)
        XCTAssertEqual(controller.items.count, 2)
        XCTAssertEqual(controller.items.first?.file.metadata, .audio(.init(duration: 1, title: " Synthetic Opus ", performer: "Synthetic Artist")))
        XCTAssertEqual(controller.items.last?.file.metadata, .audio(.init(duration: 1, title: "Synthetic MP3", performer: "Synthetic Artist")))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(controller.items.first?.file.url)), try uploadOpusAudioFixture())
        XCTAssertTrue(controller.items.allSatisfy { $0.originalFile == nil && $0.file.metadata?.voice == nil })
    }

    func testFileSelectionRetainsTheMediaRepresentationForALaterSwitch() async throws {
        let sources = try makeSources(photos: true), controller = TelegramUploadController()
        controller.bind(provider: BatchStagingProvider())
        controller.prepare(sources: [.init(source: sources[0], mode: .file)], isGrouped: false,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready)
        let item = try XCTUnwrap(controller.items.first)
        XCTAssertEqual(item.file.mode, .photo)
        XCTAssertNotNil(item.originalFile, "A later media/file switch must retain both resources")
        XCTAssertEqual(controller.file?.mode, .file, "The explicit initial file choice must remain active")
        XCTAssertEqual(controller.file?.name, "first.jpg")
        XCTAssertEqual(controller.presentation, .file)
        XCTAssertFalse(controller.isVisualMedia)
    }

    func testFileVideoSelectionRetainsVideoMetadataForALaterSwitch() async throws {
        let source = try makeSources()[0].deletingLastPathComponent().appendingPathComponent("original.mov")
        try await writeUploadVideoFixture(source)
        let bytes = try Data(contentsOf: source), controller = TelegramUploadController()
        controller.bind(provider: BatchStagingProvider())
        controller.prepare(sources: [.init(source: source, mode: .file)], isGrouped: false,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready)
        let item = try XCTUnwrap(controller.items.first)
        XCTAssertEqual(item.file.mode, .video); XCTAssertNotNil(item.file.video)
        XCTAssertNil(item.originalFile, "Video and file presentation use the same original resource")
        XCTAssertEqual(controller.presentation, .file); XCTAssertEqual(controller.file?.mode, .file)
        XCTAssertNil(controller.file?.video); XCTAssertFalse(controller.isVisualMedia)
        XCTAssertEqual(try Data(contentsOf: item.file.url), bytes)
    }

    func testUndersizedImageUsesItsOriginalFileWithoutPhotoNormalization() async throws {
        let source = try makeSources()[0].deletingLastPathComponent().appendingPathComponent("small.png")
        let image = try XCTUnwrap(CGContext(data: nil, width: 39, height: 48, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes = try Data(contentsOf: source), controller = TelegramUploadController()
        controller.bind(provider: BatchStagingProvider())
        controller.prepare(sources: [.init(source: source, mode: .photo)], isGrouped: false,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready)
        let item = try XCTUnwrap(controller.items.first)
        XCTAssertEqual(item.file.mode, .file); XCTAssertEqual(item.file.name, "small.png")
        XCTAssertNil(item.originalFile); XCTAssertEqual(controller.presentation, .file)
        XCTAssertEqual(try Data(contentsOf: item.file.url), bytes)
    }

    // Catches classifying the normalized JPEG instead of the selected source's logical size.
    func testPhotoPickerUsesSourceLogicalSizeAndRetainsTheCorrectPayloads() async throws {
        let root = try makeSources()[0].deletingLastPathComponent()
        let cases: [(Int, Int, TelegramUploadPresentation, TelegramUploadMode)] = [
            (64, 144, .file, .file), (32, 36, .media, .photo)
        ]
        for (pixels, dpi, presentation, mode) in cases {
            let source = root.appendingPathComponent("dpi-\(dpi).png")
            let context = try XCTUnwrap(CGContext(data: nil, width: pixels, height: pixels,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let bytes = try Data(contentsOf: source), controller = TelegramUploadController()
            controller.bind(provider: BatchStagingProvider())
            controller.prepare(sources: [.init(source: source, mode: .photo)], isGrouped: false,
                target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
            for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(controller.phase, .ready)
            let item = try XCTUnwrap(controller.items.first)
            defer { controller.clear() }
            try FileManager.default.removeItem(at: source)
            XCTAssertEqual(controller.presentation, presentation)
            XCTAssertEqual(item.file.mode, mode)
            XCTAssertEqual(controller.canSwitchPresentation, mode == .photo)
            let raw = try XCTUnwrap(mode == .photo ? item.originalFile : item.file)
            XCTAssertEqual(raw.name, "dpi-\(dpi).png")
            XCTAssertEqual(try Data(contentsOf: raw.url), bytes, "Raw bytes survive source removal in either presentation")
            if mode == .photo {
                XCTAssertEqual(item.file.pixelWidth, 32); XCTAssertEqual(item.file.pixelHeight, 32)
                XCTAssertEqual(item.file.name, "dpi-36.jpg")
            } else { XCTAssertNil(item.originalFile) }
        }
    }

    func testMixedMediaAndDocumentSelectionPublishesTheWholeListAsFiles() async throws {
        let photos = try makeSources(photos: true), documents = try makeSources(), controller = TelegramUploadController()
        controller.bind(provider: BatchStagingProvider())
        controller.prepare(sources: [.init(source: photos[0], mode: .photo), .init(source: documents[0], mode: .file)],
            isGrouped: true, target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.items.count, 2, "A mixed list cannot be discarded or reduced to a subset")
        XCTAssertEqual(controller.file?.mode, .file)
        XCTAssertTrue(controller.isGrouped, "File mode permits grouping photos with ordinary documents")
    }

    func testPhotoDerivativeFailureReleasesTheRawCopyBeforePublication() async throws {
        let sources = try makeSources(photos: true), controller = TelegramUploadController()
        let originalBytes = try Data(contentsOf: sources[0])
        controller.bind(provider: BatchStagingProvider())
        var rawURL: URL?
        controller.stage = { source, _ in
            rawURL = source
            XCTAssertNotEqual(source, sources[0])
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            throw TelegramUploadFileError.invalidImage
        }
        controller.prepare(sources: [.init(source: sources[0], mode: .photo)], isGrouped: false,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .failed); XCTAssertTrue(controller.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(rawURL).deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sources[0].path))
    }

    func testPhotoCancellationReleasesBothOriginalAndCompletedDerivative() async throws {
        let sources = try makeSources(photos: true), controller = TelegramUploadController()
        controller.bind(provider: BatchStagingProvider())
        var rawURL: URL?, derivative: TelegramUploadFile?, release: CheckedContinuation<Void, Never>?
        let ready = expectation(description: "Derivative completed before cancellation")
        controller.stage = { source, mode in
            rawURL = source; derivative = try await TelegramUploadFileIO.stage(source, mode: mode)
            await withCheckedContinuation { release = $0; ready.fulfill() }
            return try XCTUnwrap(derivative)
        }
        controller.prepare(sources: [.init(source: sources[0], mode: .photo)], isGrouped: false,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        await fulfillment(of: [ready], timeout: 10)
        controller.cancelPreparation(); release?.resume()
        for _ in 0..<500 where FileManager.default.fileExists(atPath: try XCTUnwrap(rawURL).path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.phase, .cancelled); XCTAssertTrue(controller.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(rawURL).deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(derivative).directory.path))
    }

    func testPhotoInitialWriteOwnsBothStagesAfterControllerDeinit() async throws {
        let sources = try makeSources(photos: true), entered = expectation(description: "Photo write owns both stages")
        let store = BatchLifetimeStore(entered: { entered.fulfill() })
        var controller: TelegramUploadController? = TelegramUploadController()
        weak var observed = controller
        controller?.bind(provider: BatchStagingProvider(), recoveryStore: store, requiresRecovery: true)
        controller?.prepare(sources: sources.map { .init(source: $0, mode: .photo) }, isGrouped: true,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        await fulfillment(of: [entered], timeout: 10)
        let files = try store.items.flatMap { [$0.file, try XCTUnwrap($0.originalFile)] }
        controller = nil; XCTAssertNil(observed); XCTAssertEqual(files.count, 4)
        for file in files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path)) }
        store.release?.resume()
        for _ in 0..<500 where files.contains(where: { FileManager.default.fileExists(atPath: $0.directory.path) }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        for file in files { XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path)) }
    }

    func testLaterStagingFailureReleasesEveryEarlierFileAndPublishesNoSubset() async throws {
        let sources = try makeSources(), controller = TelegramUploadController()
        controller.bind(provider: BatchStagingProvider())
        var first: TelegramUploadFile?
        controller.stage = { source, mode in
            if source == sources[1] { throw TelegramUploadFileError.unavailable }
            let value = try await TelegramUploadFileIO.stage(source, mode: mode); first = value; return value
        }
        controller.prepare(sources: sources.map { .init(source: $0, mode: .file) }, isGrouped: true,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        for _ in 0..<500 where controller.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.phase, .failed); XCTAssertTrue(controller.items.isEmpty); XCTAssertFalse(controller.canSend)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(first).directory.path))
    }

    func testCancellationWhileLaterFileFinishesReleasesTheWholeUnpublishedSet() async throws {
        let sources = try makeSources(), controller = TelegramUploadController()
        controller.bind(provider: BatchStagingProvider())
        var staged: [TelegramUploadFile] = [], release: CheckedContinuation<Void, Never>?
        let later = expectation(description: "Later file staged")
        controller.stage = { source, mode in
            let value = try await TelegramUploadFileIO.stage(source, mode: mode); staged.append(value)
            if source == sources[1] {
                await withCheckedContinuation { release = $0; later.fulfill() }
            }
            return value
        }
        controller.prepare(sources: sources.map { .init(source: $0, mode: .file) }, isGrouped: true,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        await fulfillment(of: [later], timeout: 10)
        controller.cancelPreparation(); release?.resume()
        for _ in 0..<500 where staged.contains(where: { FileManager.default.fileExists(atPath: $0.directory.path) }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(controller.phase, .cancelled); XCTAssertTrue(controller.items.isEmpty)
        XCTAssertEqual(staged.count, 2)
        for file in staged { XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path)) }
    }

    func testDeinitLeavesWholeSetOwnedByInitialWriteUntilItsCompletion() async throws {
        let sources = try makeSources(), entered = expectation(description: "Initial write owns files")
        let store = BatchLifetimeStore(entered: { entered.fulfill() })
        var controller: TelegramUploadController? = TelegramUploadController()
        weak var observed = controller
        controller?.bind(provider: BatchStagingProvider(), recoveryStore: store, requiresRecovery: true)
        controller?.prepare(sources: sources.map { .init(source: $0, mode: .file) }, isGrouped: true,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), captionInput: .empty)
        await fulfillment(of: [entered], timeout: 10)
        let files = store.items.map(\.file)
        controller = nil; XCTAssertNil(observed); XCTAssertEqual(files.count, 2)
        for file in files { XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path), "An in-flight write still owns every staged original") }
        store.release?.resume()
        for _ in 0..<500 where files.contains(where: { FileManager.default.fileExists(atPath: $0.directory.path) }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        for file in files { XCTAssertFalse(FileManager.default.fileExists(atPath: file.directory.path)) }
    }

    private func makeSources(photos: Bool = false) throws -> [URL] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try (photos ? ["first.jpg", "later.jpg"] : ["first.txt", "later.txt"]).map { name in
            let url = root.appendingPathComponent(name)
            if photos { try writeUploadVideoCoverFixture(url) } else { try Data(name.utf8).write(to: url) }
            return url
        }
    }
}

@MainActor private final class BatchStagingProvider: TelegramUploadBatchProvider {
    let accountID: Int64 = 1
    func submit(items: [TelegramUploadBatchItem], draft: TelegramPendingUploadDraft, target: TelegramUploadTarget,
                receive: @escaping @MainActor (TelegramUploadBatchEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Staging cannot submit a batch"); receive(.rejected); return BatchStagingLease()
    }
    func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID, caption: TelegramFormattedText,
                captionAboveMedia: Bool, mediaSpoiler: Bool, receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
        XCTFail("Staging cannot submit a file"); receive(.rejected); return BatchStagingLease()
    }
}
@MainActor private final class BatchStagingLease: TelegramUploadLease { func stop() {} }

@MainActor private final class BatchLifetimeStore: TelegramUploadRecoveryStore {
    let accountID: Int64 = 1
    let entered: () -> Void
    var release: CheckedContinuation<Void, Never>?
    var items: [TelegramUploadBatchItem] = []
    init(entered: @escaping () -> Void) { self.entered = entered }
    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, presentation: TelegramUploadPresentation,
                 target: TelegramUploadTarget, captionInput: TelegramComposerInput, captionAboveMedia: Bool,
                 mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?) async throws {
        try await prepare(preparationID: preparationID, items: items, isGrouped: isGrouped, target: target,
            captionInput: captionInput, captionAboveMedia: captionAboveMedia, mediaSpoiler: mediaSpoiler, originalDraft: originalDraft)
    }
    func prepare(preparationID: UUID, items: [TelegramUploadBatchItem], isGrouped: Bool, target: TelegramUploadTarget,
                 captionInput: TelegramComposerInput, captionAboveMedia: Bool, mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?) async throws {
        self.items = items
        await withCheckedContinuation { release = $0; entered() }
        for item in items { try TelegramUploadFileIO.validateOwnedStage(item.file) }
    }
    func load(chatID: Int64) async throws -> TelegramPendingUploadDraft? { throw TelegramUploadFileError.unavailable }
    func prepare(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget, captionInput: TelegramComposerInput,
                 captionAboveMedia: Bool, mediaSpoiler: Bool, originalDraft: TelegramComposerDraft?) async throws { throw TelegramUploadFileError.unavailable }
    func save(preparationID: UUID, chatID: Int64, captionInput: TelegramComposerInput, captionAboveMedia: Bool,
              mediaSpoiler: Bool, disposition: TelegramPendingUploadDisposition) async throws { throw TelegramUploadFileError.unavailable }
    func restoreFile(draft: TelegramPendingUploadDraft) async throws -> TelegramUploadFile { throw TelegramUploadFileError.unavailable }
    func replaceVideoCover(preparationID: UUID, file: TelegramUploadFile, target: TelegramUploadTarget, cover: TelegramUploadVideoCover?) async throws { throw TelegramUploadFileError.unavailable }
}
