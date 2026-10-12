import XCTest
@testable import MakoshTelegram

final class TelegramAlbumPresentationTests: XCTestCase {
    private func message(_ id: Int32, group: UInt32? = 7, peer: Int64 = 100,
                         namespace: Int32 = 0, thread: Int64? = nil, visual: Bool = true) -> TelegramMessage {
        var message = TelegramMessage(id: "\(peer):\(namespace):\(id)", date: Date(timeIntervalSince1970: Double(id)),
            text: "caption \(id)", author: "Synthetic", isOutgoing: false, delivery: .none)
        message.albumGroupID = group; message.nativeGroupingKey = group.map(Int64.init)
        message.attachments = [.init(id: "file-\(id)", kind: visual ? .photo : .file, name: "synthetic",
            byteCount: nil, mimeType: nil, hasPreview: true, canDownload: true)]
        message.actionMetadata = .init(peerID: peer, namespace: namespace, messageID: id, fingerprint: "v1",
            text: message.text, authorID: 999, canReply: true, canEdit: false, canForward: true,
            canDeleteLocally: true, canDeleteForEveryone: false, threadID: thread)
        return message
    }

    func testWindowGroupsKeepMembersAndLastMemberPositionWithoutFetching() {
        let items = TelegramHistoryItem.project([message(1), message(2, group: nil), message(3)], accountID: 1, chatID: 100)
        XCTAssertEqual(items.map { $0.messages.map(\.id) }, [["100:0:2"], ["100:0:1", "100:0:3"]])
        XCTAssertFalse(items[0].isAlbum); XCTAssertTrue(items[1].isVisualAlbum)
        let singleton = TelegramHistoryItem.project([message(1)], accountID: 1, chatID: 100)
        XCTAssertFalse(singleton[0].isAlbum); XCTAssertEqual(singleton[0].messages.map(\.id), ["100:0:1"])
    }

    func testNativeKeyDoesNotReplaceUIGroupIdentityAndScopeSeparatesGroups() {
        var second = message(2, group: 8); second.nativeGroupingKey = 7
        let input = [message(1), second, message(3, peer: 101), message(4, namespace: 1), message(5, thread: 9)]
        let items = TelegramHistoryItem.project(input, accountID: 1, chatID: 100)
        XCTAssertEqual(items.count, 5); XCTAssertTrue(items.allSatisfy { !$0.isAlbum })
        let a = TelegramHistoryItem.project([message(1), message(2)], accountID: 1, chatID: 100)
        let b = TelegramHistoryItem.project([message(1), message(2)], accountID: 2, chatID: 100)
        XCTAssertNotEqual(a[0].id, b[0].id)
    }

    func testUnsupportedEmptyAndDuplicateMembersNeverFormAnAlbum() {
        var empty = message(2); empty.attachments = []
        var secret = message(3); secret.canGroupMedia = false
        let items = TelegramHistoryItem.project([message(1), empty, secret], accountID: 1, chatID: 100)
        XCTAssertTrue(items.allSatisfy { !$0.isAlbum })
        let duplicates = TelegramHistoryItem.project([message(1), message(1)], accountID: 1, chatID: 100)
        XCTAssertTrue(duplicates.allSatisfy { !$0.isAlbum })
        let files = TelegramHistoryItem.project([message(1, visual: false), message(2, visual: false)], accountID: 1, chatID: 100)
        XCTAssertTrue(files[0].isAlbum); XCTAssertFalse(files[0].isVisualAlbum)
    }

    func testTwoSquareAndTwoWidePhotosHaveDistinctPacking() {
        XCTAssertEqual(TelegramAlbumMosaic.frames(aspects: [1, 1], width: 300),
            [CGRect(x: 0, y: 0, width: 148, height: 148), CGRect(x: 152, y: 0, width: 148, height: 148)])
        XCTAssertEqual(TelegramAlbumMosaic.frames(aspects: [2, 2], width: 300),
            [CGRect(x: 0, y: 0, width: 300, height: 150), CGRect(x: 0, y: 154, width: 300, height: 150)])
    }

    func testPortraitThreeAndSquareFourPreserveOrderAndFourPointGaps() {
        XCTAssertEqual(TelegramAlbumMosaic.frames(aspects: [0.5, 1, 1], width: 300),
            [CGRect(x: 0, y: 0, width: 149, height: 298), CGRect(x: 153, y: 0, width: 147, height: 147),
             CGRect(x: 153, y: 151, width: 147, height: 147)])
        XCTAssertEqual(TelegramAlbumMosaic.frames(aspects: [1, 1, 1, 1], width: 300),
            [CGRect(x: 0, y: 0, width: 148, height: 148), CGRect(x: 152, y: 0, width: 148, height: 148),
             CGRect(x: 0, y: 152, width: 148, height: 148), CGRect(x: 152, y: 152, width: 148, height: 148)])
    }

    func testManyPhotosAndMalformedGeometryStayBoundedWithoutOverlapping() {
        let frames = TelegramAlbumMosaic.frames(aspects: [1, 2, 0.5, .nan, .infinity, -1, 3, 0.8, 1, 1], width: 320)
        XCTAssertEqual(frames.count, 10)
        for (index, frame) in frames.enumerated() {
            XCTAssertGreaterThan(frame.width, 0); XCTAssertGreaterThan(frame.height, 0)
            XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, 320.0001)
            XCTAssertTrue(frame.maxY.isFinite)
            for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other)) }
        }
        XCTAssertTrue(TelegramAlbumMosaic.frames(aspects: [1, 1], width: .nan).isEmpty)
        XCTAssertTrue(TelegramAlbumMosaic.frames(aspects: Array(repeating: 1, count: 101), width: 320).isEmpty)
    }
}
