import XCTest
import Foundation
@testable import MakoshTelegram

@MainActor final class TelegramUploadBatchControllerTests: XCTestCase {
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

    private func makeSources() throws -> [URL] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try ["first.txt", "later.txt"].map { name in
            let url = root.appendingPathComponent(name); try Data(name.utf8).write(to: url); return url
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
