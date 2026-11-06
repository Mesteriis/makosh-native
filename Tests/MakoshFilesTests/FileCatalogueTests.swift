import Foundation
import MakoshCore
import XCTest
@testable import MakoshFiles

private struct TitleStub: FileSourceResolving {
    let titles: [String: String]
    func sourceTitle(for identity: MessageArchiveIdentity) async -> String? { titles[identity.conversationID] }
}

/// Answers nil until `titles` is filled, like a service whose chats load later.
private final class LateTitleStub: FileSourceResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String] = [:]
    private(set) var asked = 0
    func fill(_ titles: [String: String]) { lock.withLock { answers = titles } }
    func sourceTitle(for identity: MessageArchiveIdentity) async -> String? {
        lock.withLock {
            asked += 1
            return answers[identity.conversationID]
        }
    }
}

final class FileCatalogueTests: XCTestCase {
    private func catalogue(_ db: FilesTestDatabase) -> FileCatalogue {
        FileCatalogue(connectionString: db.connectionString, schema: db.schema) { _, _ in filesTestKey }
    }

    func testCatalogueListsStoredFilesNewestFirstWithoutRawLetterCopies() async throws {
        let db = try filesDatabase(), store = try archiveStore(db)
        let a = try storedFile(store, message: "1", attachment: "x", name: "a.pdf", capturedAt: 10)
        try storedFile(store, service: "mail", message: "2", attachment: "rfc822-source", name: "message.eml", capturedAt: 15)
        let c = try storedFile(store, service: "mail", message: "3", attachment: "0", name: "c.pdf", capturedAt: 20)
        let items = try await catalogue(db).refresh(resolver: nil)
        XCTAssertEqual(items.map(\.id), [c.id, a.id])
        XCTAssertEqual(items.map(\.service), ["mail", "telegram"])
        XCTAssertEqual(items.first?.byteCount, 1024)
    }

    func testOneRowPerAttachmentKeepsLatestRecord() async throws {
        let db = try filesDatabase(), store = try archiveStore(db)
        _ = try storedFile(store, message: "1", attachment: "x", name: "first.pdf", capturedAt: 10)
        let again = try storedFile(store, message: "1", attachment: "x", name: "second.pdf", capturedAt: 11)
        let items = try await catalogue(db).refresh(resolver: nil)
        XCTAssertEqual(items.map(\.id), [again.id])
        XCTAssertEqual(items.first?.name, "second.pdf")
    }

    func testMessageDateAndAuthorComeFromArchiveEvents() async throws {
        let db = try filesDatabase(), store = try archiveStore(db)
        let a = try storedFile(store, message: "1", attachment: "x", name: "a.pdf", capturedAt: 10)
        let c = try storedFile(store, message: "2", attachment: "y", name: "c.pdf", capturedAt: 20)
        _ = try store.append([
            MessageArchiveObservation(
                identity: a.identity, source: .synthetic,
                event: .message(.init(date: Date(timeIntervalSince1970: 1_700_000_000), text: "t", author: "Иван", isOutgoing: false)))
        ])
        let items = try await catalogue(db).refresh(resolver: nil)
        let first = try XCTUnwrap(items.first { $0.id == a.id }), second = try XCTUnwrap(items.first { $0.id == c.id })
        XCTAssertEqual(first.messageDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(first.author, "Иван")
        XCTAssertEqual(first.date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(second.messageDate)
        XCTAssertEqual(second.date, c.capturedAt)
        XCTAssertEqual(items.map(\.id), [first.id, second.id], "message date orders ahead of capture date")
    }

    func testMailAuthorIdentityIsLowercasedLikeTheDossier() async throws {
        let db = try filesDatabase(), store = try archiveStore(db)
        let letter = try storedFile(store, service: "mail", message: "1:7", attachment: "0", name: "a.pdf")
        let chat = try storedFile(store, service: "telegram", message: "0:9", attachment: "x", name: "b.pdf")
        _ = try store.append([
            MessageArchiveObservation(
                identity: letter.identity, source: .synthetic,
                event: .message(
                    .init(
                        date: Date(timeIntervalSince1970: 1), text: "t", author: "Иван", authorID: "Ivan.Petrov@Example.com",
                        isOutgoing: false))),
            MessageArchiveObservation(
                identity: chat.identity, source: .synthetic,
                event: .message(
                    .init(date: Date(timeIntervalSince1970: 2), text: "t", author: "Иван", authorID: "777000", isOutgoing: false))),
        ])
        let items = try await catalogue(db).refresh(resolver: nil)
        XCTAssertEqual(items.first { $0.id == letter.id }?.authorID, "ivan.petrov@example.com")
        XCTAssertEqual(items.first { $0.id == chat.id }?.authorID, "777000", "other services keep their ids as they are")
    }

    func testRefreshContinuesFromCursorAndKeepsEarlierItems() async throws {
        let db = try filesDatabase(), store = try archiveStore(db)
        _ = try storedFile(store, message: "1", attachment: "x", name: "a.pdf", capturedAt: 10)
        let reader = catalogue(db)
        let first = try await reader.refresh(resolver: nil)
        XCTAssertEqual(first.count, 1)
        let later = try storedFile(store, message: "2", attachment: "y", name: "b.pdf", capturedAt: 50)
        let items = try await reader.refresh(resolver: nil)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.id, later.id)
        let kept = await reader.items
        XCTAssertEqual(kept.count, 2)
    }

    func testResolverFillsSourceTitles() async throws {
        let db = try filesDatabase(), store = try archiveStore(db)
        _ = try storedFile(store, chat: "c", message: "1", attachment: "x", name: "a.pdf")
        _ = try storedFile(store, chat: "other", message: "1", attachment: "x", name: "b.pdf")
        let items = try await catalogue(db).refresh(resolver: TitleStub(titles: ["c": "Мария"]))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.sourceTitle) }), ["a.pdf": "Мария", "b.pdf": nil])
    }

    func testTamperedRowSurfacesIntegrityFailure() async throws {
        let db = try filesDatabase(), store = try archiveStore(db)
        _ = try storedFile(store, message: "1", attachment: "x", name: "a.pdf")
        try db.execute(
            "INSERT INTO \"\(db.schema)\".archive_file_events(object,state,attachment_token,ciphertext) VALUES(gen_random_uuid(),'stored','x','AAAA')"
        )
        do {
            _ = try await catalogue(db).refresh(resolver: nil)
            XCTFail("tampered row must not be skipped")
        } catch let error as FilesFailure { XCTAssertEqual(error, .integrity) }
    }

    func testTamperedMessageRowKeepsFailingInsteadOfDroppingTheFile() async throws {
        let db = try filesDatabase(), store = try archiveStore(db)
        let a = try storedFile(store, message: "1", attachment: "x", name: "a.pdf")
        _ = try store.append([
            MessageArchiveObservation(
                identity: a.identity, source: .synthetic,
                event: .message(.init(date: Date(timeIntervalSince1970: 1), text: "t", author: "Иван", isOutgoing: false)))
        ])
        // A newer, unreadable version of that message: its token is copied from the real row.
        let token = try XCTUnwrap(db.execute("SELECT message_token FROM \"\(db.schema)\".archive_events LIMIT 1").first?.first)
        try db.execute(
            "INSERT INTO \"\(db.schema)\".archive_events(observation,account_token,stream_token,message_token,event_digest,ciphertext) VALUES(gen_random_uuid(),'a','s','\(token)','d','AAAA')"
        )
        let reader = catalogue(db)
        for _ in 0..<2 {
            do {
                _ = try await reader.refresh(resolver: nil)
                XCTFail("the damaged message must keep the error visible")
            } catch let error as FilesFailure { XCTAssertEqual(error, .integrity) }
        }
        let kept = await reader.items
        XCTAssertEqual(kept, [], "nothing is shown as if the archive were fine")
    }

    func testUnknownTitlesAreAskedAgainOnTheNextRefresh() async throws {
        let db = try filesDatabase(), store = try archiveStore(db)
        _ = try storedFile(store, chat: "c", message: "1", attachment: "x", name: "a.pdf")
        let reader = catalogue(db), resolver = LateTitleStub()
        let first = try await reader.refresh(resolver: resolver)
        XCTAssertEqual(first.first?.sourceTitle, nil)
        resolver.fill(["c": "Мария"])
        let second = try await reader.refresh(resolver: resolver)
        XCTAssertEqual(second.first?.sourceTitle, "Мария")
        let third = try await reader.refresh(resolver: resolver)
        XCTAssertEqual(third.first?.sourceTitle, "Мария")
        XCTAssertEqual(resolver.asked, 2, "a known title is not asked again")
    }

    func testCategoryByExtensionAndKind() {
        XCTAssertEqual(FileCategory.classify(name: "Счёт.PDF", kind: "document"), .document)
        XCTAssertEqual(FileCategory.classify(name: "file", kind: "photo"), .image)
        XCTAssertEqual(FileCategory.classify(name: "clip.MOV", kind: "file"), .video)
        XCTAssertEqual(FileCategory.classify(name: "note.ogg", kind: "voice"), .audio)
        XCTAssertEqual(FileCategory.classify(name: "pack.tar.gz", kind: "file"), .archive)
        XCTAssertEqual(FileCategory.classify(name: "x.bin", kind: "file"), .other)
    }
}
