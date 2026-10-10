import XCTest
import MakoshCore
import TelegramCore
@testable import Postbox
@testable import MakoshTelegram

final class TelegramArchiveMappingTests: XCTestCase {
    private func entry(removed: Bool = false, media: [Media] = [], attributes: [MessageAttribute] = []) -> MakoshMessageJournalEntry {
        MakoshMessageJournalEntry(sequence: 4, eventID: UUID(uuidString: "acda936c-b876-44a5-bef4-30e33ebfd45b")!,
            capturedAt: 12345.125, id: MessageId(peerId: PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(42)), namespace: 0, id: 17),
            timestamp: 100, text: "e\u{301} · original", authorId: PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(77)),
            flags: [.Incoming], attributes: attributes, media: media, removed: removed)
    }
    func testRemovalFirstRetainsPriorSnapshotAndStableFullIdentityAndCaptureTime() throws {
        let source = entry(removed: true, attributes: [EditedMessageAttribute(date: 110, isHidden: false)])
        let first = telegramArchiveItem(source, accountID: 9), replay = telegramArchiveItem(source, accountID: 9)
        XCTAssertEqual(first.sequence, 4); XCTAssertEqual(first.observations, replay.observations)
        XCTAssertEqual(first.observations.count, 2)
        let snapshot = first.observations[0]
        XCTAssertEqual(snapshot.id, source.eventID)
        XCTAssertEqual(snapshot.identity.accountID, "9")
        XCTAssertEqual(snapshot.identity.conversationID, String(source.id.peerId.toInt64()))
        XCTAssertEqual(snapshot.identity.messageID, "0:17")
        XCTAssertEqual(snapshot.observedAt.timeIntervalSince1970, 12345.125)
        if case let .message(content) = snapshot.event {
            XCTAssertEqual(Array(content.text.utf8), Array(source.text.utf8))
            XCTAssertEqual(content.editedAt?.timeIntervalSince1970, 110)
            XCTAssertFalse(content.isOutgoing)
        } else { XCTFail("Pre-removal text must be captured first") }
        XCTAssertEqual(first.observations[1].event, .removedFromSource)
        XCTAssertNotEqual(first.observations[1].id, snapshot.id)
        XCTAssertEqual(first.observations[1].id, telegramArchiveRemovalID(source.eventID))
    }
    func testProjectionNeverArchivesAccessHashesFileReferencesOrResourceCachePaths() throws {
        let resource = CloudDocumentMediaResource(datacenterId: 2, fileId: 123, accessHash: 777_123_456,
            size: 12, fileReference: Data("synthetic-private-reference".utf8), fileName: "sample.txt")
        let file = TelegramMediaFile(fileId: MediaId(namespace: 0, id: 123), partialReference: nil,
            resource: resource, previewRepresentations: [], videoThumbnails: [], immediateThumbnailData: nil,
            mimeType: "text/plain", size: 12, attributes: [.FileName(fileName: "sample.txt")], alternativeRepresentations: [])
        let value = telegramArchiveItem(entry(media: [file]), accountID: 9)
        let encoded = try JSONEncoder().encode(value.observations)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("777123456")); XCTAssertFalse(text.contains("synthetic-private-reference"))
        XCTAssertFalse(text.contains("accessHash")); XCTAssertFalse(text.contains("fileReference"))
        if case let .message(content) = value.observations[0].event {
            XCTAssertEqual(content.attachments.first?.name, "sample.txt")
            XCTAssertEqual(content.attachments.first?.size, 12)
        } else { XCTFail("Expected snapshot") }
    }
}
