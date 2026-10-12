import XCTest
import AppKit
@testable import MakoshApp
@testable import MakoshTelegram

@MainActor final class TelegramUploadDropTests: XCTestCase {
    private func source() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Synthetic Drop.png")
        try writeUploadVideoCoverFixture(file)
        return file
    }

    // Catches sending on drop, losing input formatting, or treating the File zone as Photo.
    func testFileDropPreparesAnExplicitFileWithTheCapturedRichCaptionWithoutSending() async throws {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
        let caption = try TelegramComposerInput(formattedText: .init(text: "Drop 😀", entities: [.init(offset: 0, length: 4, kind: .bold)]))
        XCTAssertTrue(model.updateComposerInput(caption, contextID: model.uploadContextID, chatID: 10001))
        let capture = try XCTUnwrap(TelegramUploadDropCapture(model: model))
        XCTAssertTrue(capture.prepare(urls: [try source()], asMedia: false, model: model, photoSize: .standard))
        for _ in 0..<500 where model.upload.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        defer { model.upload.clear() }
        XCTAssertEqual(model.upload.phase, .ready); XCTAssertEqual(model.upload.presentation, .file)
        XCTAssertEqual(model.upload.captionInput, caption); XCTAssertEqual(model.upload.target?.chatID, 10001)
        XCTAssertEqual(model.upload.file?.name, "Synthetic Drop.png")
        XCTAssertTrue(model.upload.messageIDs.isEmpty)
        XCTAssertTrue(model.isComposerSuspended); XCTAssertEqual(model.composerInput, .empty)
        model.upload.cancelPreparation()
        XCTAssertFalse(model.isComposerSuspended); XCTAssertEqual(model.composerInput, caption)
    }

    // Catches routing the Media zone to documents or duplicating a dropped URL.
    func testMediaDropUsesTheNormalPhotoPipelineAndDeduplicatesWithoutSending() async throws {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
        let capture = try XCTUnwrap(TelegramUploadDropCapture(model: model)), file = try source()
        XCTAssertTrue(capture.prepare(urls: [file, file], asMedia: true, model: model, photoSize: .standard))
        for _ in 0..<500 where model.upload.phase == .preparing { try await Task.sleep(for: .milliseconds(10)) }
        defer { model.upload.clear() }
        XCTAssertEqual(model.upload.phase, .ready); XCTAssertEqual(model.upload.presentation, .media)
        XCTAssertEqual(model.upload.items.count, 1); XCTAssertEqual(model.upload.file?.mode, .photo)
        XCTAssertNotNil(model.upload.items.first?.originalFile); XCTAssertTrue(model.upload.messageIDs.isEmpty)
    }

    // Catches applying a drag begun in another chat/account or before a new caption edit.
    func testStaleDropNeverStartsReadingFiles() throws {
        for change in 0..<3 {
            let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
            let capture = try XCTUnwrap(TelegramUploadDropCapture(model: model))
            if change == 0 { model.selectedChatID = 10002 }
            if change == 1 { model.disconnect() }
            if change == 2 { model.draft = "New draft" }
            XCTAssertFalse(capture.prepare(urls: [URL(fileURLWithPath: "/synthetic/not-opened")],
                asMedia: false, model: model, photoSize: .standard))
            XCTAssertEqual(model.upload.phase, .idle); XCTAssertNil(model.upload.target)
        }
    }

    // Catches accepting remote file URLs, ordinary links, or part of a malformed multi-item drop.
    func testInvalidDropIsRejectedAsAWholeBeforeStaging() throws {
        let model = TelegramModel.syntheticPreview(); model.selectedChatID = 10001
        let capture = try XCTUnwrap(TelegramUploadDropCapture(model: model)), file = try source()
        for urls in [[], [URL(string: "https://example.invalid/file.png")!],
                     [file, URL(string: "file://other-host/path.png")!]] {
            XCTAssertFalse(capture.prepare(urls: urls, asMedia: true, model: model, photoSize: .standard))
            XCTAssertEqual(model.upload.phase, .idle)
        }
    }
}
