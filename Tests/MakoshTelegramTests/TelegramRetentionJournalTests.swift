import XCTest
import Foundation
import SwiftSignalKit
import TelegramCore
@testable import Postbox

private final class JournalFixtureAttribute: MessageAttribute {
    let value: String
    init(_ value: String) { self.value = value }
    init(decoder: PostboxDecoder) { value = decoder.decodeStringForKey("v", orElse: "") }
    func encode(_ encoder: PostboxEncoder) { encoder.encodeString(value, forKey: "v") }
}
private final class JournalFixtureMedia: Media {
    var id: MediaId? { nil }
    var peerIds: [PeerId] { [] }
    var indexableText: String? { nil }
    let value: String
    init(_ value: String) { self.value = value }
    init(decoder: PostboxDecoder) { value = decoder.decodeStringForKey("v", orElse: "") }
    func encode(_ encoder: PostboxEncoder) { encoder.encodeString(value, forKey: "v") }
    func isLikelyToBeUpdated() -> Bool { false }
    func preventsAutomaticMessageSendingFailure() -> Bool { false }
    func isEqual(to other: Media) -> Bool { (other as? JournalFixtureMedia)?.value == value }
    func isSemanticallyEqual(to other: Media) -> Bool { isEqual(to: other) }
}

final class TelegramRetentionJournalTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        declareEncodable(JournalFixtureAttribute.self) { JournalFixtureAttribute(decoder: $0) }
        declareEncodable(JournalFixtureMedia.self) { JournalFixtureMedia(decoder: $0) }
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func database<T>(_ url: URL, _ body: (SqliteValueBox) throws -> T) throws -> T {
        let queue = Queue(name: "makosh-retention-test")
        var result: Result<T, Error>!
        queue.sync {
            result = Result {
                let box = try XCTUnwrap(SqliteValueBox(basePath: url.path, queue: queue,
                    isTemporary: false, isReadOnly: false, useCaches: false,
                    removeDatabaseOnError: false, encryptionParameters: nil, upgradeProgress: { _ in }))
                return try body(box)
            }
        }
        return try result.get()
    }
    private func append(_ journal: MakoshMessageJournal, text: String, peer: Int64 = 100, removed: Bool = false) {
        journal.append(id: MessageId(peerId: PeerId(peer), namespace: 0, id: 42), timestamp: 123,
            text: text, authorId: PeerId(200), flags: [.Incoming], attributes: [], media: [], removed: removed)
    }

    func testSameTransactionVersionsRemovalAndRestartHaveStableIdentity() throws {
        let root = try directory()
        let original = try database(root) { box in
            box.begin()
            let journal = MakoshMessageJournal(valueBox: box)
            append(journal, text: "original")
            append(journal, text: "edited")
            append(journal, text: "edited", removed: true)
            let values = try journal.read(limit: 100)
            XCTAssertEqual(values.map(\.text), ["original", "edited", "edited"])
            XCTAssertEqual(values.map(\.removed), [false, false, true])
            XCTAssertEqual(values.map(\.sequence), [1, 2, 3])
            XCTAssertEqual(Set(values.map(\.eventID)).count, 3)
            XCTAssertEqual(values.first?.authorId, PeerId(200))
            XCTAssertTrue(values.first?.flags.contains(.Incoming) == true)
            box.commit()
            return values.map { ($0.eventID, $0.capturedAt) }
        }
        try database(root) { box in
            box.begin()
            let journal = MakoshMessageJournal(valueBox: box)
            let redelivered = try journal.read(limit: 100)
            XCTAssertEqual(redelivered.map(\.eventID), original.map { $0.0 })
            XCTAssertEqual(redelivered.map(\.capturedAt), original.map { $0.1 })
            XCTAssertTrue(redelivered.allSatisfy { $0.capturedAt.isFinite && $0.capturedAt > 0 })
            append(journal, text: "next")
            XCTAssertEqual(try journal.read(limit: 100).last?.sequence, 4)
            box.commit()
        }
    }

    func testExactAcknowledgementNeverDropsUncommittedOtherSequences() throws {
        let root = try directory()
        try database(root) { box in
            box.begin()
            let journal = MakoshMessageJournal(valueBox: box)
            append(journal, text: "one"); append(journal, text: "two", peer: 300); append(journal, text: "three")
            XCTAssertThrowsError(try journal.acknowledge(sequences: [1, 999]))
            XCTAssertEqual(try journal.read(limit: 100).map(\.sequence), [1, 2, 3])
            try journal.acknowledge(sequences: [2, 2])
            XCTAssertEqual(try journal.read(limit: 100).map(\.sequence), [1, 3])
            box.commit()
        }
        try database(root) { box in
            box.begin()
            let journal = MakoshMessageJournal(valueBox: box)
            XCTAssertEqual(try journal.read(limit: 100).map(\.sequence), [1, 3])
            try journal.acknowledge(sequences: [1, 3])
            append(journal, text: "four")
            XCTAssertEqual(try journal.read(limit: 100).map(\.sequence), [4])
            box.commit()
        }
    }

    func testBoundedReadAndAllPeersWithoutHistoryWindow() throws {
        try database(directory()) { box in
            box.begin()
            let journal = MakoshMessageJournal(valueBox: box)
            for number in 0..<1005 { append(journal, text: String(number), peer: Int64(number + 100)) }
            XCTAssertEqual(try journal.read(limit: -1).count, 0)
            XCTAssertEqual(try journal.read(limit: 7).count, 7)
            XCTAssertEqual(try journal.read(limit: Int.max).count, 1000)
            XCTAssertEqual(try journal.read(limit: 1).first?.text, "0")
            XCTAssertThrowsError(try journal.acknowledge(sequences: Array(repeating: 1, count: 1001)))
            box.commit()
        }
    }

    func testCorruptJournalReadThrowsWithoutAcknowledgingAnything() throws {
        try database(directory()) { box in
            box.begin()
            let journal = MakoshMessageJournal(valueBox: box)
            append(journal, text: "preserved")
            let key = ValueBoxKey(length: 8); key.setInt64(0, value: 2)
            box.set(MakoshMessageJournal.entries, key: key, value: MemoryBuffer(data: Data("invalid".utf8)))
            XCTAssertThrowsError(try journal.read(limit: 100))
            XCTAssertEqual(try journal.read(limit: 1).first?.text, "preserved")
            box.commit()
        }
    }

    func testAttributesAndMediaAreOwnedEncodedSnapshotsNotLiveReferences() throws {
        let root = try directory()
        try database(root) { box in
            box.begin()
            let journal = MakoshMessageJournal(valueBox: box)
            journal.append(id: MessageId(peerId: PeerId(100), namespace: 0, id: 1), timestamp: 1,
                text: "snapshot", authorId: nil, flags: [],
                attributes: [JournalFixtureAttribute("original attribute")],
                media: [JournalFixtureMedia("original media")], removed: true)
            box.commit()
        }
        try database(root) { box in
            box.begin()
            let item = try XCTUnwrap(MakoshMessageJournal(valueBox: box).read(limit: 1).first)
            XCTAssertEqual((item.attributes.first as? JournalFixtureAttribute)?.value, "original attribute")
            XCTAssertEqual((item.media.first as? JournalFixtureMedia)?.value, "original media")
            XCTAssertTrue(item.removed)
            box.commit()
        }
    }


    func testRealPostboxCentralInsertReplaceEditDeleteRangeCaptureUnknownPeers() throws {
        let root = try directory()
        let opened = expectation(description: "synthetic Postbox open")
        var postbox: Postbox?
        let key = try XCTUnwrap(ValueBoxEncryptionParameters.Key(data: Data(repeating: 1, count: 32)))
        let salt = try XCTUnwrap(ValueBoxEncryptionParameters.Salt(data: Data(repeating: 2, count: 16)))
        let opening = openPostbox(basePath: root.path, seedConfiguration: telegramPostboxSeedConfiguration,
            encryptionParameters: ValueBoxEncryptionParameters(forceEncryptionIfNoSet: true, key: key, salt: salt),
            timestampForAbsoluteTimeBasedOperations: 1, isMainProcess: true, isTemporary: false,
            isReadOnly: false, useCopy: false, useCaches: false, removeDatabaseOnError: false)
            .start(next: { value in
                if case let .postbox(value) = value { postbox = value; opened.fulfill() }
            })
        defer { opening.dispose() }
        wait(for: [opened], timeout: 20)
        let store = try XCTUnwrap(postbox)
        let completed = expectation(description: "central capture committed")
        let peer = PeerId(namespace: Namespaces.Peer.CloudUser, id: ._internalFromInt64Value(999))
        func message(_ number: Int32, text: String) -> StoreMessage {
            StoreMessage(id: MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: number),
                globallyUniqueId: nil, groupingKey: nil, threadId: nil, timestamp: number,
                flags: [.Incoming], tags: [], globalTags: [], localTags: [], forwardInfo: nil,
                authorId: peer, text: text, attributes: [JournalFixtureAttribute("attribute-" + text)],
                media: [JournalFixtureMedia("media-" + text)])
        }
        var events: [UUID] = []
        let transaction = store.transaction { transaction -> Bool in
            // No peer/chat-list registration and no history view exist for this synthetic peer.
            _ = transaction.addMessages((1...55).map { message(Int32($0), text: "original-\($0)") }, location: .Random)
            _ = transaction.addMessages([message(1, text: "replacement")], location: .Random)
            let id = MessageId(peerId: peer, namespace: Namespaces.Message.Cloud, id: 1)
            transaction.updateMessage(id) { _ in .update(message(1, text: "edited")) }
            transaction.deleteMessages([id], forEachMedia: nil)
            transaction.deleteMessagesInRange(peerId: peer, namespace: Namespaces.Message.Cloud,
                minId: 2, maxId: 4, forEachMedia: nil)
            do {
                let journal = try transaction.makoshArchiveJournal(limit: 1000)
                XCTAssertGreaterThan(journal.count, 55)
                XCTAssertEqual(Set(journal.filter { !$0.removed }.map(\.id)).count, 55)
                let first = journal.filter { $0.id == id }
                XCTAssertTrue(first.contains { $0.text == "original-1" && !$0.removed })
                XCTAssertTrue(first.contains { $0.text == "replacement" && !$0.removed })
                XCTAssertTrue(first.contains { $0.text == "edited" && !$0.removed })
                let removal = try XCTUnwrap(first.last)
                XCTAssertTrue(removal.removed)
                XCTAssertEqual(removal.text, "edited")
                XCTAssertEqual((removal.attributes.first as? JournalFixtureAttribute)?.value, "attribute-edited")
                XCTAssertEqual((removal.media.first as? JournalFixtureMedia)?.value, "media-edited")
                XCTAssertEqual(Set(journal.filter(\.removed).map { $0.id.id }), [1, 2, 3, 4])
                XCTAssertNil(transaction.getMessage(id))
                events = journal.map(\.eventID)
                return true
            } catch { XCTFail("Journal capture failed"); return false }
        }.start(next: { _ in completed.fulfill() })
        defer { transaction.dispose() }
        wait(for: [completed], timeout: 20)
        let reread = expectation(description: "journal remains after central transaction")
        let reading = store.transaction { transaction -> Bool in
            do { XCTAssertEqual(try transaction.makoshArchiveJournal(limit: 1000).map(\.eventID), events) }
            catch { XCTFail("Journal reread failed") }
            return true
        }.start(next: { _ in reread.fulfill() })
        defer { reading.dispose() }
        wait(for: [reread], timeout: 20)
    }

}
