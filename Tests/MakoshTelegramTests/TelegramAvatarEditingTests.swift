import XCTest
import CoreGraphics
import ImageIO
import Postbox
import TelegramCore
@testable import MakoshTelegram

@MainActor final class TelegramAvatarEditingTests: XCTestCase {
    private func target(_ peer: Int64 = 101, kind: TelegramAvatarKind = .main) -> TelegramAvatarTarget {
        .init(accountID: 101, peerID: peer, kind: kind)
    }
    private func fixture(_ target: TelegramAvatarTarget? = nil, photo: Int64? = 5, editable: Bool = true) -> TelegramAvatarSnapshot {
        .init(target: target ?? self.target(), title: "Synthetic avatar", photoID: photo, canEdit: editable)
    }
    func testSnapshotRequiresNativeTargetIdentityAndFallbackOwnership() {
        XCTAssertTrue(fixture().isValid)
        XCTAssertFalse(fixture(.init(accountID: 101, peerID: 102, kind: .fallback)).isValid)
        XCTAssertFalse(fixture(.init(accountID: 101, peerID: -1, kind: .main)).isValid)
        XCTAssertFalse(fixture(photo: 0).isValid)
        XCTAssertFalse(fixture(.init(accountID: 0, peerID: 101, kind: .main)).isValid)
    }
    func testOpenRejectsWrongAccountAndMalformedResponse() {
        let provider = AvatarProvider(), controller = TelegramAvatarEditingController()
        controller.bind(provider); controller.open(target())
        provider.reads[0](.success(fixture(.init(accountID: 102, peerID: 102, kind: .main))))
        XCTAssertEqual(controller.status, .failed); XCTAssertNil(controller.snapshot)
        controller.open(.init(accountID: 102, peerID: 102, kind: .main))
        XCTAssertEqual(provider.reads.count, 1)
    }
    func testStaleReadAndPickerDraftCannotSurviveRebind() {
        let provider = AvatarProvider(), controller = TelegramAvatarEditingController()
        controller.bind(provider); controller.open(target()); let context = controller.contextID
        controller.close(); provider.reads[0](.success(fixture()))
        XCTAssertNil(controller.snapshot)
        controller.open(target()); provider.reads[1](.success(fixture()))
        XCTAssertFalse(controller.stageRemoval(contextID: context)); XCTAssertNil(controller.draft)
        XCTAssertTrue(controller.stageRemoval(contextID: controller.contextID))
        controller.bind(AvatarProvider(accountID: 102)); XCTAssertNil(controller.draft)
    }
    func testMissingRightsAndAbsentPhotoRefuseRemoval() {
        let provider = AvatarProvider(), controller = TelegramAvatarEditingController()
        controller.bind(provider); controller.open(target()); provider.reads[0](.success(fixture(editable: false)))
        XCTAssertFalse(controller.stageRemoval(contextID: controller.contextID))
        controller.refresh(); provider.reads[1](.success(fixture(photo: nil)))
        XCTAssertFalse(controller.stageRemoval(contextID: controller.contextID))
        XCTAssertTrue(provider.writes.isEmpty)
    }
    func testExplicitDraftConfirmationAndCancellation() throws {
        let provider = AvatarProvider(), controller = TelegramAvatarEditingController()
        controller.bind(provider); controller.open(target()); provider.reads[0](.success(fixture()))
        XCTAssertTrue(controller.stageRemoval(contextID: controller.contextID)); let draft = try XCTUnwrap(controller.draft)
        XCTAssertTrue(provider.writes.isEmpty)
        controller.discardDraft(); XCTAssertFalse(controller.apply(draftID: draft.id, contextID: controller.contextID))
        XCTAssertTrue(controller.stageRemoval(contextID: controller.contextID)); let current = try XCTUnwrap(controller.draft)
        XCTAssertFalse(controller.apply(draftID: current.id, contextID: UUID()))
        XCTAssertTrue(controller.apply(draftID: current.id, contextID: controller.contextID))
        XCTAssertEqual(provider.writes.count, 1); XCTAssertEqual(provider.writes[0].basis, fixture())
        XCTAssertFalse(controller.apply(draftID: current.id, contextID: controller.contextID))
    }
    func testEmptyCompletionCannotPublishSuccessAndCommittedTimeoutRequiresRefresh() throws {
        let provider = AvatarProvider(), controller = TelegramAvatarEditingController()
        controller.bind(provider); controller.open(target()); provider.reads[0](.success(fixture()))
        XCTAssertTrue(controller.stageRemoval(contextID: controller.contextID))
        XCTAssertTrue(controller.apply(draftID: try XCTUnwrap(controller.draft).id, contextID: controller.contextID))
        XCTAssertEqual(controller.phase, .uploading)
        XCTAssertTrue(provider.writes[0].receive(.committing)); XCTAssertEqual(controller.phase, .committing)
        controller.cancelUpload(); XCTAssertEqual(controller.phase, .committing)
        controller.timeoutMutation(); XCTAssertEqual(controller.phase, .uncertain)
        XCTAssertFalse(provider.writes[0].receive(.saved(fixture(photo: nil))))
        controller.close(); controller.open(target()); provider.reads[1](.success(fixture(photo: nil)))
        XCTAssertEqual(controller.phase, .uncertain)
        controller.refresh(); provider.reads[2](.success(fixture(photo: nil)))
        XCTAssertEqual(controller.phase, .idle)
    }
    func testCancelUploadPreservesDraftAndRevokesLateCommit() throws {
        let provider = AvatarProvider(), controller = TelegramAvatarEditingController()
        controller.bind(provider); controller.open(target()); provider.reads[0](.success(fixture()))
        XCTAssertTrue(controller.stageRemoval(contextID: controller.contextID))
        let draft = try XCTUnwrap(controller.draft)
        XCTAssertTrue(controller.apply(draftID: draft.id, contextID: controller.contextID))
        controller.cancelUpload()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.draft?.id, draft.id)
        XCTAssertFalse(provider.writes[0].receive(.committing))
        XCTAssertFalse(controller.isBusy)
    }
    func testCancelBeforeCommitDoesNotCreateUnknownWriteButRejectsLateCommit() throws {
        let provider = AvatarProvider(), controller = TelegramAvatarEditingController()
        controller.bind(provider); controller.open(target()); provider.reads[0](.success(fixture()))
        XCTAssertTrue(controller.stageRemoval(contextID: controller.contextID))
        XCTAssertTrue(controller.apply(draftID: try XCTUnwrap(controller.draft).id, contextID: controller.contextID))
        controller.close(); XCTAssertFalse(provider.writes[0].receive(.committing))
        controller.open(target()); provider.reads[1](.success(fixture()))
        XCTAssertEqual(controller.phase, .idle)
    }
    func testChangedBasisAndWrongAcknowledgementNeverPublishSaved() throws {
        let provider = AvatarProvider(), controller = TelegramAvatarEditingController()
        controller.bind(provider); controller.open(target()); provider.reads[0](.success(fixture()))
        XCTAssertTrue(controller.stageRemoval(contextID: controller.contextID))
        XCTAssertTrue(controller.apply(draftID: try XCTUnwrap(controller.draft).id, contextID: controller.contextID))
        XCTAssertTrue(provider.writes[0].receive(.failed(.changed)))
        XCTAssertEqual(controller.phase, .changed)
        controller.refresh(); provider.reads[1](.success(fixture()))
        XCTAssertTrue(controller.stageRemoval(contextID: controller.contextID))
        XCTAssertTrue(controller.apply(draftID: try XCTUnwrap(controller.draft).id, contextID: controller.contextID))
        XCTAssertTrue(provider.writes[1].receive(.committing))
        XCTAssertTrue(provider.writes[1].receive(.saved(fixture(photo: 5))))
        XCTAssertEqual(controller.phase, .uncertain); XCTAssertEqual(controller.snapshot?.photoID, 5)
    }
    func testSquareCropSurvivesReferenceCanvasRoundingRotationAndFlip() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let preview = TelegramImagePreview(image: try XCTUnwrap(context.makeImage()))
        var crop = try TelegramUploadVideoCoverCrop(imageSize: CGSize(width: 600, height: 400), videoSize: CGSize(width: 1, height: 1))
        crop.fitInitialSelection(canvasSize: CGSize(width: 512, height: 342))
        crop.rotate(); crop.flipHorizontally()
        let photo = try TelegramAvatarPhoto.prepare(preview: preview, crop: crop.rect, transform: crop.transform)
        XCTAssertEqual(photo.preview.image.width, 400); XCTAssertEqual(photo.preview.image.height, 400)
        XCTAssertTrue(photo.isValid)
    }
    func testPhotoPreparationProducesSquareBoundedMetadataFreeJpeg() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let preview = TelegramImagePreview(image: try XCTUnwrap(context.makeImage()), originalExtension: "png", originalSHA256: nil)
        let photo = try TelegramAvatarPhoto.prepare(preview: preview, crop: CGRect(x: 1.0/6, y: 0, width: 2.0/3, height: 1))
        XCTAssertEqual(photo.preview.image.width, 640); XCTAssertEqual(photo.preview.image.height, 640)
        XCTAssertTrue(photo.isValid)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(photo.bytes as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        for key in [kCGImagePropertyGPSDictionary,kCGImagePropertyExifDictionary,kCGImagePropertyIPTCDictionary] { XCTAssertNil(props[key]) }
        XCTAssertThrowsError(try TelegramAvatarPhoto.prepare(preview: preview, crop: CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertThrowsError(try TelegramAvatarPhoto.prepare(preview: preview, crop: CGRect(x: -1, y: 0, width: 1, height: 1)))
    }
}

@MainActor private final class AvatarRequest: TelegramAvatarEditingRequest { func cancel() {} }
@MainActor private final class AvatarProvider: TelegramAvatarEditingProvider {
    let accountID: Int64
    struct Write { let basis: TelegramAvatarSnapshot; let receive: @MainActor (TelegramAvatarEditingEvent) -> Bool }
    var reads: [@MainActor (Result<TelegramAvatarSnapshot, TelegramAvatarError>) -> Void] = []
    var writes: [Write] = []
    init(accountID: Int64 = 101) { self.accountID = accountID }
    func load(target: TelegramAvatarTarget, receive: @escaping @MainActor (Result<TelegramAvatarSnapshot, TelegramAvatarError>) -> Void) -> any TelegramAvatarEditingRequest {
        reads.append(receive); return AvatarRequest()
    }
    func apply(basis: TelegramAvatarSnapshot, photo: TelegramAvatarPhoto?, receive: @escaping @MainActor (TelegramAvatarEditingEvent) -> Bool) -> any TelegramAvatarEditingRequest {
        writes.append(.init(basis: basis, receive: receive)); return AvatarRequest()
    }
}
