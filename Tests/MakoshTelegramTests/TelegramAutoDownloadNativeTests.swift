import XCTest
import TelegramCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

private nonisolated func seedAutomaticFile(_ box: Postbox, incoming: Bool = true,
    protected: Bool = false, spoiler: Bool = false, size: Int64 = 100) -> Signal<TelegramAttachmentSource?, NoError> {
    box.transaction { tx in
        let peer = PeerId(37), id = MessageId(peerId: PeerId(37), namespace: 0, id: 1)
        let user = TelegramUser(id: peer, accessHash: nil, firstName: "Synthetic", lastName: nil, username: nil,
            phone: nil, photo: [], botInfo: nil, restrictionInfo: nil, flags: [], emojiStatus: nil,
            usernames: [], storiesHidden: nil, nameColor: nil, backgroundEmojiId: nil, profileColor: nil,
            profileBackgroundEmojiId: nil, subscriberCount: nil, verificationIconFileId: nil)
        tx.updatePeersInternal([user], update: { _, new in new })
        let file = TelegramMediaFile(fileId: .init(namespace: Namespaces.Media.CloudFile, id: 100), partialReference: nil,
            resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 100, accessHash: 53, size: size,
                fileReference: Data([1, 2]), fileName: "Synthetic.bin"), previewRepresentations: [], videoThumbnails: [],
            immediateThumbnailData: nil, mimeType: "application/octet-stream", size: size,
            attributes: [.FileName(fileName: "Synthetic.bin")], alternativeRepresentations: [])
        let message = StoreMessage(id: id, globallyUniqueId: nil, groupingKey: nil, threadId: nil,
            timestamp: 100, flags: protected ? [.Incoming, .CopyProtected] : incoming ? [.Incoming] : [],
            tags: [], globalTags: [], localTags: [], forwardInfo: nil, authorId: peer, text: "Synthetic",
            attributes: spoiler ? [MediaSpoilerMessageAttribute()] : [], media: [file])
        if tx.getMessage(id) == nil { _ = tx.addMessages([message], location: .Random) }
        else { tx.updateMessage(id) { _ in .update(message) } }
        return tx.getMessage(id).flatMap { telegramAttachments($0).first }
    }
}
private nonisolated func automaticAdmission(_ box: Postbox, source: TelegramAttachmentSource,
    preferences: TelegramAutoDownloadPreferences, contact: Bool = false) -> Signal<Bool, NoError> {
    let admission = telegramAutomaticDownloadAdmission(postbox: box, source: source, preferences: preferences)
    if contact { return box.transaction { $0.replaceContactPeerIds([PeerId(37)]) } |> mapToSignal { _ in admission } }
    return admission
}
@MainActor final class TelegramAutoDownloadNativeTests: XCTestCase {
    func testFreshNativeContactClassificationControlsAdmission() async throws {
        let box = try await telegramDataPostbox(test: self)
        let seeded = try await telegramDataValue(seedAutomaticFile(box), test: self)
        let source = try XCTUnwrap(seeded)
        var p = TelegramAutoDownloadPreferences(); p.enabled = true; p.files.peers = [.contacts]
        let before = try await telegramDataValue(automaticAdmission(box, source: source, preferences: p), test: self)
        XCTAssertFalse(before)
        let after = try await telegramDataValue(automaticAdmission(box, source: source, preferences: p, contact: true), test: self)
        XCTAssertTrue(after)
    }
    func testChangedProtectedSpoilerOrOutgoingSourceIsRejectedAfterOriginalSnapshot() async throws {
        let box = try await telegramDataPostbox(test: self)
        let seeded = try await telegramDataValue(seedAutomaticFile(box), test: self)
        let source = try XCTUnwrap(seeded)
        var p = TelegramAutoDownloadPreferences(); p.enabled = true; p.files.peers = [.privateChats]
        func allowed(_ item: TelegramAttachmentSource) async throws -> Bool {
            try await telegramDataValue(automaticAdmission(box, source: item, preferences: p), test: self)
        }
        let initial = try await allowed(source); XCTAssertTrue(initial)
        _ = try await telegramDataValue(seedAutomaticFile(box, size: 200), test: self)
        let changed = try await allowed(source); XCTAssertFalse(changed)
        for (incoming, protected, spoiler) in [(false,false,false), (true,true,false), (true,false,true)] {
            let seeded = try await telegramDataValue(seedAutomaticFile(box,
                incoming: incoming, protected: protected, spoiler: spoiler), test: self)
            let current = try XCTUnwrap(seeded)
            let result = try await allowed(current); XCTAssertFalse(result)
        }
    }
}
