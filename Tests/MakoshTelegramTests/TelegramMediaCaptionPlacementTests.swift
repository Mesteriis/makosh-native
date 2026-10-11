import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramMediaCaptionPlacementTests: XCTestCase {
    private func photo() -> TelegramMediaImage {
        TelegramMediaImage(imageId: MediaId(namespace: 0, id: 40), representations: [],
            immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    }
    private func file(mime: String = "application/pdf", attributes: [TelegramMediaFileAttribute] = []) -> TelegramMediaFile {
        TelegramMediaFile(fileId: MediaId(namespace: 0, id: 50), partialReference: nil,
            resource: EmptyMediaResource(), previewRepresentations: [], videoThumbnails: [],
            immediateThumbnailData: nil, mimeType: mime, size: nil, attributes: attributes, alternativeRepresentations: [])
    }
    private func message(_ media: Media, inverted: Bool, id: Int32 = 1, text: String = "Caption") -> Message {
        let peerID = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(100))
        return Message(stableId: UInt32(id), stableVersion: 0, id: MessageId(peerId: peerID, namespace: Namespaces.Message.Cloud, id: id),
            globallyUniqueId: nil, groupingKey: 7, groupInfo: .init(stableId: 7), threadId: nil, timestamp: 1,
            flags: [], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil,
            author: nil, text: text, attributes: inverted ? [InvertMediaMessageAttribute()] : [], media: [media], peers: SimpleDictionary(),
            associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:],
            associatedThreadInfo: nil, associatedStories: [:])
    }

    func testNativePhotoPlacementSurvivesHistoryAndSearchProjectionWithoutChangingTheAttachment() {
        let source = message(photo(), inverted: true)
        let entry = MessageHistoryEntry(message: source, isRead: false, location: nil, monthLocation: nil,
            attributes: MutableMessageHistoryEntryAttributes(authorIsContact: false))
        let history = TelegramMessage(entry, accountID: 1), search = TelegramMessage(source, accountID: 1)
        let ordinary = TelegramMessage(message(photo(), inverted: false), accountID: 1)
        XCTAssertTrue(history.captionAboveMedia); XCTAssertTrue(search.captionAboveMedia)
        XCTAssertFalse(ordinary.captionAboveMedia)
        XCTAssertEqual(history.attachments, search.attachments); XCTAssertEqual(search.attachments, ordinary.attachments)
        XCTAssertNotEqual(search, ordinary, "Caption order must invalidate the message presentation")
    }

    func testNativeVideoAcceptsInversionButWebmAndNonvisualCardsDoNot() {
        let video = TelegramMediaFileAttribute.Video(duration: 12, size: .init(width: 320, height: 200),
            flags: [], preloadSize: nil, coverTime: nil, videoCodec: nil)
        XCTAssertTrue(TelegramMessage(message(file(mime: "video/mp4", attributes: [video]), inverted: true)).captionAboveMedia)
        for media in [file(), file(mime: "video/webm", attributes: [video]),
                      file(mime: "audio/ogg", attributes: [.Audio(isVoice: true, duration: 1, title: nil, performer: nil, waveform: nil)]),
                      file(mime: "video/mp4", attributes: [.Video(duration: 1, size: .init(width: 100, height: 100),
                          flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)])] {
            XCTAssertFalse(TelegramMessage(message(media, inverted: true)).captionAboveMedia)
        }
    }

    func testVisualAlbumUsesFirstMembersPlacementWithFirstNonemptyCaption() throws {
        let first = TelegramMessage(message(photo(), inverted: true, text: ""))
        let second = TelegramMessage(message(photo(), inverted: false, id: 2, text: "Second caption"))
        let album = try XCTUnwrap(TelegramHistoryItem.project([first, second], accountID: 1, chatID: 100).first)
        XCTAssertEqual(album.visualCaption?.id, second.id); XCTAssertTrue(album.visualCaptionAboveMedia)
        let below = try XCTUnwrap(TelegramHistoryItem.project([second, first], accountID: 1, chatID: 100).first)
        XCTAssertEqual(below.visualCaption?.id, second.id); XCTAssertFalse(below.visualCaptionAboveMedia)
        let empty = try XCTUnwrap(TelegramHistoryItem.project([first, TelegramMessage(message(photo(), inverted: true, id: 2, text: ""))], accountID: 1, chatID: 100).first)
        XCTAssertNil(empty.visualCaption); XCTAssertFalse(empty.visualCaptionAboveMedia)
        let files = try XCTUnwrap(TelegramHistoryItem.project([TelegramMessage(message(file(), inverted: true)),
            TelegramMessage(message(file(), inverted: true, id: 2))], accountID: 1, chatID: 100).first)
        XCTAssertNil(files.visualCaption); XCTAssertFalse(files.visualCaptionAboveMedia)
    }
}
