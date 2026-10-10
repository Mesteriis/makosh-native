import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramUploadMappingTests: XCTestCase {
    private func fixture(mode: TelegramUploadMode, width: Int32? = nil, height: Int32? = nil) -> TelegramUploadFile {
        TelegramUploadFile(id: UUID(), name: "synthetic.unknown-extension", size: 42, mode: mode,
            pixelWidth: width, pixelHeight: height, url: URL(fileURLWithPath: "/synthetic/payload"),
            directory: URL(fileURLWithPath: "/synthetic"))
    }
    func testDocumentUsesIndependentLocalResourceAndMIMEFallback() throws {
        let source = fixture(mode: .file)
        let (resource, reference) = try XCTUnwrap(telegramUploadMedia(source))
        guard case .standalone = reference else { return XCTFail("New media must be standalone") }
        let file = try XCTUnwrap(reference.media as? TelegramMediaFile)
        XCTAssertEqual(file.mimeType, "application/octet-stream")
        XCTAssertEqual(file.size, 42)
        XCTAssertEqual(file.fileName, source.name)
        XCTAssertEqual(file.fileId.namespace, Namespaces.Media.LocalFile)
        XCTAssertEqual(file.resource.id, resource.id)
        XCTAssertTrue(file.previewRepresentations.isEmpty)
        XCTAssertNil(file.partialReference)
        let second = try XCTUnwrap(telegramUploadMedia(source))
        XCTAssertNotEqual(resource.id, second.0.id)
    }
    func testPhotoUsesMeasuredDimensionsWithoutRemoteReferences() throws {
        let (resource, reference) = try XCTUnwrap(telegramUploadMedia(fixture(mode: .photo, width: 30, height: 60)))
        let image = try XCTUnwrap(reference.media as? TelegramMediaImage)
        XCTAssertEqual(image.imageId.namespace, Namespaces.Media.LocalImage)
        XCTAssertNil(image.reference); XCTAssertNil(image.partialReference)
        XCTAssertEqual(image.representations.count, 1)
        XCTAssertEqual(image.representations[0].dimensions, PixelDimensions(width: 30, height: 60))
        XCTAssertEqual(image.representations[0].resource.id, resource.id)
    }
    func testPhotoWithoutValidDimensionsCannotBeEnqueued() {
        XCTAssertNil(telegramUploadMedia(fixture(mode: .photo)))
        XCTAssertNil(telegramUploadMedia(fixture(mode: .photo, width: 0, height: 60)))
        XCTAssertNil(telegramUploadMedia(fixture(mode: .photo, width: 30, height: -1)))
    }
    func testCacheVerificationRequiresExactRegularFileAndRejectsSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache")
        try Data([1, 2, 3]).write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertTrue(validUploadCacheFile(file.path, size: 3))
        XCTAssertFalse(validUploadCacheFile(file.path, size: 4))
        XCTAssertFalse(validUploadCacheFile(link.path, size: 3))
        XCTAssertFalse(validUploadCacheFile(directory.path, size: 0))
        XCTAssertFalse(validUploadCacheFile(file.path + "\0", size: 3))
    }
}

@MainActor final class TelegramUploadDraftTests: XCTestCase {
    func testOldPickerContextCannotStartStaging() throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        let target = try XCTUnwrap(model.uploadTarget)
        model.prepareUpload(source: URL(fileURLWithPath: "/synthetic/not-opened"), mode: .file,
                            target: target, caption: "caption", contextID: UUID())
        XCTAssertEqual(model.upload.phase, .idle)
        XCTAssertNil(model.upload.target)
    }
    func testAcknowledgementClearsOnlyExactCaptionInCapturedChat() throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        let target = try XCTUnwrap(model.uploadTarget)
        model.draft = "caption"
        model.captureUploadDraft(target: target, caption: "caption")
        model.acknowledgeUpload(target: target, caption: "caption")
        XCTAssertEqual(model.draft, "")
        model.draft = "caption"
        model.captureUploadDraft(target: target, caption: "caption")
        model.draft = "edited"
        model.acknowledgeUpload(target: target, caption: "caption")
        XCTAssertEqual(model.draft, "edited")
    }
    func testAcknowledgementPreservesAnotherChatAndAccountDrafts() throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        let first = try XCTUnwrap(model.uploadTarget)
        model.draft = "first"
        model.captureUploadDraft(target: first, caption: "first")
        model.selectedChatID = model.chats[1].id
        model.draft = "second"
        model.acknowledgeUpload(target: first, caption: "first")
        XCTAssertEqual(model.draft, "second")
        model.selectedChatID = first.chatID
        XCTAssertEqual(model.draft, "")
        model.draft = "keep"
        model.acknowledgeUpload(target: TelegramUploadTarget(accountID: 99, chatID: first.chatID, title: "Other"), caption: "keep")
        XCTAssertEqual(model.draft, "keep")
    }
    func testUnicodeOnlyEditSurvivesAcknowledgement() throws {
        let model = TelegramModel.syntheticPreview()
        model.selectedChatID = try XCTUnwrap(model.chats.first).id
        let target = try XCTUnwrap(model.uploadTarget)
        model.draft = "e\u{301}"
        model.captureUploadDraft(target: target, caption: "é")
        model.acknowledgeUpload(target: target, caption: "é")
        XCTAssertEqual(Array(model.draft.utf8), Array("e\u{301}".utf8))
    }
}
