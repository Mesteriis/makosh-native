import XCTest
import TelegramCore
import Postbox
@testable import MakoshTelegram

final class TelegramUploadSpoilerTests: XCTestCase {
    // Missing/unsupported metadata must never silently restore an open photo.
    func testSpoilerSchemaRejectsFileAndLegacyClaims() throws {
        let base = try pendingUploadFixture()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 3)
        XCTAssertEqual(json["mediaSpoiler"] as? Bool, false)
        XCTAssertFalse(try pendingUploadMutating(base) { $0["mediaSpoiler"] = true }.isValid)
        let photo = try pendingUploadMutating(base) {
            var file = $0["file"] as! [String: Any], attachment = file["attachment"] as! [String: Any]
            attachment["kind"] = "photo"; file["attachment"] = attachment; $0["file"] = file
            $0["mediaSpoiler"] = true
        }
        XCTAssertTrue(photo.isValid)
        for version in [1, 2] {
            let legacy = try pendingUploadMutating(photo) {
                $0["schemaVersion"] = version; $0.removeValue(forKey: "mediaSpoiler")
                if version == 1 { $0.removeValue(forKey: "captionAboveMedia") }
            }
            XCTAssertTrue(legacy.isValid)
            XCTAssertFalse(try pendingUploadMutating(photo) { $0["schemaVersion"] = version }.isValid)
        }
        XCTAssertFalse(try pendingUploadMutating(photo) { $0["schemaVersion"] = 4 }.isValid)
        XCTAssertThrowsError(try pendingUploadMutating(photo) { $0.removeValue(forKey: "mediaSpoiler") })
        XCTAssertThrowsError(try pendingUploadMutating(photo) { $0["mediaSpoiler"] = "true" })
    }

    func testPhotoSpoilerIsIndependentOfPlacementAndPreservesRichReply() throws {
        let photo = TelegramUploadFile(id: UUID(), name: "synthetic.jpg", size: 3, mode: .photo,
            pixelWidth: 30, pixelHeight: 60, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused"))
        let reference = try XCTUnwrap(telegramUploadMedia(photo)).1
        let reply = TelegramMessageActionSource(metadata: .init(peerID: 42, namespace: 0, messageID: 7,
            fingerprint: "source", text: "reply", authorID: 2, canReply: true, canEdit: false,
            canForward: true, canDeleteLocally: true, canDeleteForEveryone: false, threadID: 99), accountID: 1, chatID: 42)
        let target = TelegramUploadTarget(accountID: 1, chatID: 42, title: "Synthetic", replySource: reply)
        let rich = try TelegramFormattedText(text: "😀", entities: [.init(offset: 0, length: 2, kind: .bold)])
        for spoiler in [false, true] {
            for above in [false, true] {
                let message = try XCTUnwrap(telegramUploadMessage(caption: rich, reference: reference, target: target,
                    replySource: reply, captionAboveMedia: above, mediaSpoiler: spoiler))
                guard case let .message(text, attributes, _, _, thread, subject, _, _, _, _) = message else { return XCTFail("Photo required") }
                XCTAssertEqual(attributes.filter { $0 is MediaSpoilerMessageAttribute }.count, spoiler ? 1 : 0)
                XCTAssertEqual(attributes.filter { $0 is InvertMediaMessageAttribute }.count, above ? 1 : 0)
                XCTAssertEqual(text, "😀"); XCTAssertEqual(thread, 99); XCTAssertEqual(subject?.messageId.id, 7)
                let entities = try XCTUnwrap(attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.first)
                XCTAssertEqual(entities.entities.first?.range, 0..<2)
            }
        }
        XCTAssertNil(telegramUploadMessage(caption: rich, reference: reference, target: target,
            replySource: nil, mediaSpoiler: true), "Spoiler cannot bypass reply preflight")
        let file = TelegramUploadFile(id: UUID(), name: "synthetic.txt", size: 3, mode: .file,
            pixelWidth: nil, pixelHeight: nil, url: photo.url, directory: photo.directory)
        XCTAssertNil(telegramUploadMessage(caption: "", reference: try XCTUnwrap(telegramUploadMedia(file)).1,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), replySource: nil, mediaSpoiler: true))
        guard case let .message(_, attributes, _, _, _, _, _, _, _, _)? = telegramUploadMessage(caption: "",
            reference: reference, target: .init(accountID: 1, chatID: 42, title: "Synthetic"), replySource: nil, mediaSpoiler: true)
        else { return XCTFail("Empty caption still permits photo spoiler") }
        XCTAssertEqual(attributes.filter { $0 is MediaSpoilerMessageAttribute }.count, 1)
    }
}

@MainActor final class TelegramUploadSpoilerControllerTests: XCTestCase {
    private final class Lease: TelegramUploadLease { func stop() {} }
    private final class Provider: TelegramUploadProvider {
        let accountID: Int64 = 1
        var submitted: [(TelegramFormattedText, Bool, Bool)] = []
        var callback: (@MainActor (TelegramUploadEvent) -> Void)?
        func submit(file: TelegramUploadFile, target: TelegramUploadTarget, preparationID: UUID,
                    caption: TelegramFormattedText, captionAboveMedia: Bool, mediaSpoiler: Bool,
                    receive: @escaping @MainActor (TelegramUploadEvent) -> Void) -> any TelegramUploadLease {
            submitted.append((caption, captionAboveMedia, mediaSpoiler)); callback = receive; return Lease()
        }
    }
    private func ready(_ mode: TelegramUploadMode = .photo) async -> (TelegramUploadController, Provider) {
        let controller = TelegramUploadController(), provider = Provider()
        controller.stage = { _, _ in .init(id: UUID(), name: "synthetic", size: 3, mode: mode,
            pixelWidth: 30, pixelHeight: 60, url: URL(fileURLWithPath: "/unused"), directory: URL(fileURLWithPath: "/unused")) }
        controller.discard = { _ in }; controller.bind(provider: provider)
        controller.prepare(source: URL(fileURLWithPath: "/unused"), mode: mode,
            target: .init(accountID: 1, chatID: 42, title: "Synthetic"), caption: "")
        for _ in 0..<100 { await Task.yield() }
        return (controller, provider)
    }
    func testSpoilerSurvivesInputAndPlacementButFrozenSubmissionRejectsStaleMenus() async throws {
        let (controller, provider) = await ready()
        let context = controller.captionContextID, initial = controller.captionRevision
        XCTAssertFalse(controller.mediaSpoiler)
        XCTAssertTrue(controller.updateMediaSpoiler(true, contextID: context, revision: initial))
        XCTAssertTrue(controller.mediaSpoiler); XCTAssertFalse(controller.captionAboveMedia)
        XCTAssertFalse(controller.updateMediaSpoiler(false, contextID: context, revision: initial))
        XCTAssertFalse(controller.updateCaptionPlacement(true, contextID: context, revision: initial))
        XCTAssertTrue(controller.updateCaptionPlacement(true, contextID: context, revision: controller.captionRevision))
        let rich = try TelegramComposerInput(formattedText: TelegramFormattedText(text: "😀", entities: [.init(offset: 0, length: 2, kind: .bold)]), selection: .init(location: 2, length: 0))
        XCTAssertTrue(controller.updateCaptionInput(rich, contextID: context))
        XCTAssertTrue(controller.mediaSpoiler); XCTAssertTrue(controller.captionAboveMedia)
        XCTAssertEqual(controller.captionInput, rich)
        let revision = controller.captionRevision
        controller.send()
        XCTAssertFalse(controller.updateMediaSpoiler(false, contextID: context, revision: revision))
        XCTAssertEqual(provider.submitted.count, 1); XCTAssertEqual(provider.submitted.first?.0.text, "😀")
        XCTAssertEqual(provider.submitted.first?.1, true); XCTAssertEqual(provider.submitted.first?.2, true)
        provider.callback?(.committing); provider.callback?(.uncertain)
        XCTAssertFalse(controller.updateMediaSpoiler(false, contextID: controller.captionContextID, revision: controller.captionRevision))
        controller.clear(); XCTAssertFalse(controller.mediaSpoiler)
        XCTAssertFalse(controller.updateMediaSpoiler(true, contextID: context, revision: revision))
    }
    func testPhotoCanDisableSpoilerAndFileCannotEnableIt() async {
        let (photo, _) = await ready()
        XCTAssertTrue(photo.updateMediaSpoiler(true, contextID: photo.captionContextID, revision: photo.captionRevision))
        XCTAssertTrue(photo.updateMediaSpoiler(false, contextID: photo.captionContextID, revision: photo.captionRevision))
        XCTAssertFalse(photo.mediaSpoiler); XCTAssertTrue(photo.canSend)
        let (file, _) = await ready(.file)
        XCTAssertFalse(file.updateMediaSpoiler(true, contextID: file.captionContextID, revision: file.captionRevision))
        XCTAssertFalse(file.mediaSpoiler); XCTAssertTrue(file.canSend)
    }
}
