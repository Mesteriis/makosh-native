import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramUploadCaptionPlacementTests: XCTestCase {
    // A missing native placement attribute must not silently send below media.
    func testPhotoPlacementRetainsRichCaptionReplyAndThread() throws {
        let file = TelegramUploadFile(id: UUID(), name: "synthetic.jpg", size: 3, mode: .photo,
            pixelWidth: 30, pixelHeight: 60, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
        let reference = try XCTUnwrap(telegramUploadMedia(file)).1
        let reply = TelegramMessageActionSource(metadata: .init(peerID: 42, namespace: 0, messageID: 7,
            fingerprint: "source", text: "reply", authorID: 2, canReply: true, canEdit: false,
            canForward: true, canDeleteLocally: true, canDeleteForEveryone: false, threadID: 99), accountID: 1, chatID: 42)
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic", replySource: reply)
        let rich = try TelegramFormattedText(text: "e\u{301} 😀", entities: [.init(offset: 3, length: 2, kind: .bold)])
        for above in [true, false] {
            let message = try XCTUnwrap(telegramUploadMessage(caption: rich, reference: reference,
                target: target, replySource: reply, captionAboveMedia: above))
            guard case let .message(text, attributes, _, _, thread, subject, _, _, _, _) = message else { return XCTFail("Media message required") }
            XCTAssertEqual(attributes.filter { $0 is InvertMediaMessageAttribute }.count, above ? 1 : 0)
            let entities = try XCTUnwrap(attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first)
            XCTAssertEqual(text, "e\u{301} 😀"); XCTAssertEqual(entities.entities.count, 1)
            XCTAssertEqual(entities.entities[0].range, 3..<5)
            XCTAssertEqual(thread, 99); XCTAssertEqual(subject?.messageId.id, 7)
        }
        XCTAssertNil(telegramUploadMessage(caption: rich, reference: reference, target: target,
            replySource: nil, captionAboveMedia: true), "Placement cannot bypass reply validation")
    }

    func testEmptyPhotoCaptionCanBeAboveButFileCannot() throws {
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic")
        for mode in [TelegramUploadMode.photo, .file] {
            let file = TelegramUploadFile(id: UUID(), name: "synthetic", size: 3, mode: mode,
                pixelWidth: 30, pixelHeight: 60, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
            let reference = try XCTUnwrap(telegramUploadMedia(file)).1
            let message = telegramUploadMessage(caption: "", reference: reference, target: target,
                replySource: nil, captionAboveMedia: true)
            if mode == .file { XCTAssertNil(message) }
            else {
                guard case let .message(text, attributes, _, _, _, _, _, _, _, _)? = message else { return XCTFail("Empty photo caption allowed") }
                XCTAssertEqual(text, ""); XCTAssertEqual(attributes.filter { $0 is InvertMediaMessageAttribute }.count, 1)
            }
        }
    }

    // Old drafts default below; malformed/future drafts may never erase a choice.
    func testPendingDraftMigrationAndStrictPlacementValidation() throws {
        let base = try pendingUploadFixture()
        let legacy = try pendingUploadMutating(base) { $0["schemaVersion"] = 1; $0.removeValue(forKey: "captionAboveMedia") }
        XCTAssertTrue(legacy.isValid)
        let newJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        XCTAssertEqual(newJSON["schemaVersion"] as? Int, 2)
        XCTAssertEqual(newJSON["captionAboveMedia"] as? Bool, false)
        let photo = try pendingUploadMutating(base) {
            $0["schemaVersion"] = 2; $0["captionAboveMedia"] = true
            var file = $0["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
            attachment["kind"] = "photo"; file["attachment"] = attachment; $0["file"] = file
        }
        XCTAssertTrue(photo.isValid)
        let roundtrip = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(photo)) as? [String: Any])
        XCTAssertEqual(roundtrip["captionAboveMedia"] as? Bool, true)
        XCTAssertFalse(try pendingUploadMutating(base) { $0["captionAboveMedia"] = true }.isValid)
        XCTAssertFalse(try pendingUploadMutating(photo) { $0["schemaVersion"] = 1 }.isValid)
        XCTAssertFalse(try pendingUploadMutating(photo) { $0["schemaVersion"] = 3 }.isValid)
        XCTAssertThrowsError(try pendingUploadMutating(photo) { $0.removeValue(forKey: "captionAboveMedia") })
    }
}

@MainActor final class TelegramUploadCaptionPlacementControllerTests: XCTestCase {
    private final class Lease: TelegramUploadLease { func stop() {} }
    private final class Provider: TelegramUploadProvider {
        let accountID: Int64 = 1
        var submitted: [(TelegramFormattedText, Bool)] = []
        var callback: (@MainActor (TelegramUploadEvent) -> Void)?
        func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID,
                    caption: TelegramFormattedText, captionAboveMedia: Bool,
                    receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
            submitted.append((caption, captionAboveMedia)); callback = receive; return Lease()
        }
    }
    private func ready(_ mode: TelegramUploadMode = .photo) async -> (TelegramUploadController, Provider) {
        let controller = TelegramUploadController(), provider = Provider()
        controller.stage = { _, _ in .init(id: UUID(), name: "synthetic", size: 3, mode: mode,
            pixelWidth: 30, pixelHeight: 60, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused")) }
        controller.discard = { _ in }
        controller.bind(provider: provider)
        controller.prepare(source: URL(fileURLWithPath: "/unused"), mode: mode,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), caption: "")
        for _ in 0..<100 { await Task.yield() }
        return (controller, provider)
    }
    func testPlacementSurvivesInputAndFrozenSubmissionRejectsStaleMenus() async throws {
        let (controller, provider) = await ready()
        let context = controller.captionContextID, initial = controller.captionRevision
        XCTAssertFalse(controller.captionAboveMedia)
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: context, revision: initial))
        XCTAssertTrue(controller.captionAboveMedia); XCTAssertTrue(controller.canSend)
        XCTAssertFalse(controller.updateCaptionPlacement(false, contextID: context, revision: initial))
        let rich = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "😀", entities: [.init(offset: 0, length: 2, kind: .bold)]))
        let beforeInput = controller.captionRevision
        XCTAssertTrue(controller.updateCaptionInput(rich, contextID: context))
        XCTAssertTrue(controller.captionAboveMedia)
        XCTAssertFalse(controller.updateCaptionPlacement(false, contextID: context, revision: beforeInput))
        let revision = controller.captionRevision
        controller.send()
        XCTAssertFalse(controller.updateCaptionPlacement(false, contextID: context, revision: revision))
        XCTAssertEqual(provider.submitted.count, 1); XCTAssertEqual(provider.submitted.first?.0.text, "😀")
        XCTAssertEqual(provider.submitted.first?.1, true)
        provider.callback?(.committing); provider.callback?(.uncertain)
        XCTAssertFalse(controller.updateCaptionPlacement(false, contextID: controller.captionContextID, revision: controller.captionRevision))
        controller.clear()
        XCTAssertFalse(controller.captionAboveMedia)
        XCTAssertFalse(controller.updateCaptionPlacement(true, contextID: context, revision: revision))
    }
    func testFilePreparationCannotEnableCaptionAbove() async {
        let (controller, _) = await ready(.file)
        XCTAssertFalse(controller.updateCaptionPlacement(true, contextID: controller.captionContextID, revision: controller.captionRevision))
        XCTAssertFalse(controller.captionAboveMedia); XCTAssertTrue(controller.canSend)
    }
}
