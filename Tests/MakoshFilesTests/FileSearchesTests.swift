import Foundation
import XCTest
@testable import MakoshCore
@testable import MakoshFiles

final class FileDestinationSearchTests: XCTestCase {
    private func telegram(_ title: String) -> FileDestination {
        FileDestination(kind: .telegram(accountID: "1", chatID: Int64(title.hashValue & 0xFFFF)), title: title, subtitle: "Telegram")
    }
    private func mail(_ title: String, _ address: String) -> FileDestination {
        FileDestination(kind: .mail(address: address, contactID: nil), title: title, subtitle: address)
    }

    func testPrefixBeatsWordPrefixBeatsSubstringAndIsYoInsensitive() {
        let items = [telegram("Команда Мария"), telegram("Тамара"), mail("Мария Иванова", "m@example.org"), telegram("Семён")]
        XCTAssertEqual(
            FileDestinationSearch.rank(items, query: "мар", limit: 10).map(\.title), ["Мария Иванова", "Команда Мария", "Тамара"])
        XCTAssertEqual(FileDestinationSearch.rank(items, query: "СЕМЕН", limit: 10).map(\.title), ["Семён"])
        XCTAssertEqual(
            FileDestinationSearch.rank(items, query: "example", limit: 10).map(\.title), ["Мария Иванова"], "the subtitle counts")
        XCTAssertEqual(FileDestinationSearch.rank(items, query: " ", limit: 2).count, 2, "an empty query keeps the order, limited")
    }

    func testIDsDistinguishKinds() {
        let a = FileDestination(
            kind: .whatsapp(accountID: UUID(uuidString: "5A0B5C46-0000-4000-8000-000000000001")!, chatID: "x"), title: "A", subtitle: "")
        XCTAssertEqual(a.id, "whatsapp:5a0b5c46-0000-4000-8000-000000000001:x")
        XCTAssertEqual(telegram("t").id.hasPrefix("telegram:1:"), true)
        XCTAssertEqual(mail("m", "M@Example.org").id, "mail:m@example.org")
    }
}

@MainActor final class FilePickerSearchTests: XCTestCase {
    private func item(_ name: String) -> FileCatalogueItem {
        let hash = String(repeating: "ab", count: 32), id = UUID()
        let record = ArchiveFileRecord(
            id: id, identity: .init(service: "mail", accountID: "1", conversationID: "c", messageID: name),
            attachment: .init(id: name, kind: "document", name: name, size: 1), objectKey: "vaults/x/files/\(id)", storageID: hash,
            receipt: ArchiveFileEnvelopeReceipt(byteCount: 2, sha256: hash, plaintextByteCount: 1, plaintextSHA256: hash),
            capturedAt: Date(timeIntervalSince1970: 1), state: .stored, purpose: nil)
        return FileCatalogueItem(record: record, messageDate: nil, author: nil, sourceTitle: "Почта")
    }
    nonisolated private static func document(_ id: Int, _ title: String) -> PaperlessDocument {
        PaperlessDocument(id: id, title: title, created: nil, documentType: nil, tags: [], originalFileName: nil)
    }

    func testCatalogueMatchesAtOnceAndPaperlessAfterThreeCharacters() async throws {
        let connection = UUID()
        let calls = Collector<String>()
        let search = FilePickerSearch(
            catalogue: { [self.item("Счёт за ноябрь.pdf"), self.item("Договор.docx")] },
            paperless: { _, query in
                calls.append(query)
                return [Self.document(1, "Счёт за октябрь")]
            }, connections: { [connection] }, debounce: .zero)
        search.update(query: "сч")
        XCTAssertEqual(search.results.map(\.title), ["Счёт за ноябрь.pdf"])
        XCTAssertEqual(calls.values, [], "two characters never reach Paperless")
        search.update(query: "счё")
        await search.settle()
        XCTAssertEqual(search.results.map(\.title), ["Счёт за ноябрь.pdf", "Счёт за октябрь"])
        XCTAssertEqual(calls.values, ["счё"])
        XCTAssertEqual(search.results.last?.subtitle, "Paperless")
        XCTAssertEqual(search.results.first?.subtitle, "Файл · Почта")
    }

    func testLateAnswerToAnEarlierQueryIsDropped() async throws {
        let gate = Gate()
        let search = FilePickerSearch(
            catalogue: { [] },
            paperless: { _, query in
                if query == "first" { await gate.wait() }
                return [Self.document(query == "first" ? 1 : 2, query)]
            }, connections: { [UUID()] }, debounce: .zero)
        search.update(query: "first")
        search.update(query: "second")
        await search.settle()
        XCTAssertEqual(search.results.map(\.title), ["second"])
        await gate.open()
        await search.settle()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(search.results.map(\.title), ["second"], "the first answer never lands")
    }

    func testPaperlessFailureKeepsCatalogueResults() async throws {
        let search = FilePickerSearch(
            catalogue: { [self.item("Отчёт.pdf")] }, paperless: { _, _ in throw FilesFailure.unauthorized }, connections: { [UUID()] },
            debounce: .zero)
        search.update(query: "отч")
        await search.settle()
        XCTAssertEqual(search.results.map(\.title), ["Отчёт.pdf"])
        XCTAssertEqual(search.failure, FilesFailure.unauthorized.errorDescription)
    }
}

/// A gate a scripted callback can wait on until the test opens it.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}
