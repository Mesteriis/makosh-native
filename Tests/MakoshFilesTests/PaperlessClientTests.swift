import Foundation
import XCTest
@testable import MakoshFiles

final class PaperlessClientTests: XCTestCase {
    private let connection = PaperlessConnection(name: "Docs", baseURL: URL(string: "https://doc.example")!)
    private var client: PaperlessClient!
    private typealias Reply = PaperlessStubProtocol.Reply

    override func setUp() {
        super.setUp()
        client = PaperlessClient(connection: connection, token: "secret-token", session: PaperlessStubProtocol.session)
        PaperlessStubProtocol.reset([])
    }
    private var requests: [URLRequest] { PaperlessStubProtocol.requests }
    private func temporaryFile(_ bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paperless-\(UUID().uuidString).pdf")
        try Data(repeating: 0x25, count: bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testStatusSendsTokenAndVersionAndReadsCount() async throws {
        PaperlessStubProtocol.reset([.json(#"{"count":1115,"results":[]}"#, headers: ["X-Version": "3.0.5"])])
        let status = try await client.status()
        XCTAssertEqual(status, PaperlessStatus(documentCount: 1115, version: "3.0.5"))
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://doc.example/api/documents/?page_size=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json; version=\(PaperlessClient.apiVersion)")
    }

    func testNotAcceptableRetriesOnceWithoutVersion() async throws {
        PaperlessStubProtocol.reset([.json(#"{"detail":"Invalid version"}"#, status: 406), .json(#"{"count":3}"#)])
        let status = try await client.status()
        XCTAssertEqual(status.documentCount, 3)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Accept"), "application/json")
        PaperlessStubProtocol.reset([.json("{}", status: 406), .json("{}", status: 406)])
        do {
            _ = try await client.status()
            XCTFail("second 406 is a rejection")
        } catch let error as FilesFailure { XCTAssertEqual(error, .rejected(status: 406, reason: "")) }
        XCTAssertEqual(requests.count, 2)
    }

    func testDocumentsParseDateOnlyAndDateTimeCreated() async throws {
        PaperlessStubProtocol.reset([
            .json(
                #"{"count":2,"next":"https://doc.example/api/documents/?page=2","results":[{"id":1,"title":"Счёт","created":"2026-11-05","document_type":4,"tags":[1,2],"original_file_name":"a.pdf"},{"id":2,"title":"Договор","created":"2026-11-05T10:00:00+01:00","document_type":null,"tags":[]}]}"#
            )
        ])
        let page = try await client.documents(query: "счёт", page: 1)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items.map(\.id), [1, 2])
        XCTAssertEqual(page.items[0].documentType, 4)
        XCTAssertEqual(page.items[0].tags, [1, 2])
        XCTAssertEqual(page.items[0].originalFileName, "a.pdf")
        var day = DateComponents()
        day.year = 2026
        day.month = 11
        day.day = 5
        XCTAssertEqual(page.items[0].created, Calendar(identifier: .gregorian).date(from: day))
        XCTAssertEqual(page.items[1].created, ISO8601DateFormatter().date(from: "2026-11-05T10:00:00+01:00"))
        XCTAssertNil(page.items[1].documentType)
        let url = try XCTUnwrap(requests.first?.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://doc.example/api/documents/?"), url)
        XCTAssertTrue(url.contains("query=%D1%81%D1%87%D1%91%D1%82"), url)
        XCTAssertTrue(url.contains("ordering=-created") && url.contains("page_size=50") && url.contains("page=1"), url)
        PaperlessStubProtocol.reset([.json(#"{"count":0,"next":null,"results":[]}"#)])
        let last = try await client.documents(query: "", page: 1)
        XCTAssertFalse(last.hasMore)
        XCTAssertFalse(try XCTUnwrap(requests.first?.url?.absoluteString).contains("query="))
    }

    func testTagsAndDocumentTypesFollowNextPages() async throws {
        PaperlessStubProtocol.reset([
            .json(#"{"next":"https://doc.example/api/tags/?page=2","results":[{"id":1,"name":"Входящие"}]}"#),
            .json(#"{"next":null,"results":[{"id":2,"name":"Проверено"}]}"#),
        ])
        let tags = try await client.tags()
        XCTAssertEqual(tags, [PaperlessNamed(id: 1, name: "Входящие"), PaperlessNamed(id: 2, name: "Проверено")])
        XCTAssertEqual(
            requests.map { $0.url!.absoluteString },
            ["https://doc.example/api/tags/?page_size=100", "https://doc.example/api/tags/?page=2"])
        PaperlessStubProtocol.reset([.json(#"{"next":null,"results":[{"id":7,"name":"Финансы"}]}"#)])
        let types = try await client.documentTypes()
        XCTAssertEqual(types, [PaperlessNamed(id: 7, name: "Финансы")])
    }

    func testUploadBuildsMultipartAndReturnsTaskID() async throws {
        PaperlessStubProtocol.reset([.json(#""7f1c2a3b-0000-4000-8000-000000000001""#)])
        let file = try temporaryFile(64)
        var day = DateComponents()
        day.year = 2026
        day.month = 11
        day.day = 5
        let options = PaperlessUpload(
            title: "Счёт за ноябрь", created: Calendar(identifier: .gregorian).date(from: day), documentType: 4, tags: [1, 2])
        let task = try await client.upload(file: file, name: "Счёт.pdf", options: options)
        XCTAssertEqual(task, "7f1c2a3b-0000-4000-8000-000000000001")
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://doc.example/api/documents/post_document/")
        XCTAssertEqual(request.httpMethod, "POST")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)
        let body = String(decoding: PaperlessStubProtocol.bodies[0], as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"document\"; filename=\"Счёт.pdf\""), body)
        XCTAssertTrue(body.contains("name=\"title\"\r\n\r\nСчёт за ноябрь"), body)
        XCTAssertTrue(body.contains("name=\"created\"\r\n\r\n2026-11-05"), body)
        XCTAssertTrue(body.contains("name=\"document_type\"\r\n\r\n4"), body)
        XCTAssertEqual(body.components(separatedBy: "name=\"tags\"").count - 1, 2, body)
        XCTAssertTrue(body.contains(String(repeating: "%", count: 64)))
    }

    func testTaskStatesIncludingDuplicateMessage() async throws {
        PaperlessStubProtocol.reset([
            .json(#"[{"task_id":"t","status":"PENDING","result":null,"related_document":null}]"#),
            .json(#"[{"task_id":"t","status":"STARTED","result":null}]"#),
            .json(#"[{"task_id":"t","status":"SUCCESS","result":"Success. New document id 123 created","related_document":"123"}]"#),
            .json(#"[{"task_id":"t","status":"FAILURE","result":"Not consuming Счёт.pdf: It is a duplicate of Счёт.pdf (#120)"}]"#),
            .json("[]"),
        ])
        let first = try await client.task(id: "t"), second = try await client.task(id: "t")
        let third = try await client.task(id: "t"), fourth = try await client.task(id: "t")
        XCTAssertEqual(first, .pending)
        XCTAssertEqual(second, .started)
        XCTAssertEqual(third, .success(documentID: 123))
        XCTAssertEqual(fourth, .failure(message: "Not consuming Счёт.pdf: It is a duplicate of Счёт.pdf (#120)"))
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://doc.example/api/tasks/?task_id=t")
        do {
            _ = try await client.task(id: "t")
            XCTFail("an unknown task is unexpected")
        } catch let error as FilesFailure { XCTAssertEqual(error, .unexpectedResponse) }
    }

    func testUnauthorizedTooLargeRejectedUnreachable() async throws {
        PaperlessStubProtocol.reset([.json(#"{"detail":"Invalid token."}"#, status: 401)])
        await assertFailure(.unauthorized) { _ = try await self.client.status() }
        PaperlessStubProtocol.reset([.json("", status: 403)])
        await assertFailure(.unauthorized) { _ = try await self.client.status() }
        PaperlessStubProtocol.reset([Reply(status: 413, body: Data("<html>too large</html>".utf8), headers: ["Content-Type": "text/html"])])
        await assertFailure(.tooLarge) {
            _ = try await self.client.upload(file: try self.temporaryFile(8), name: "a.pdf", options: .init(title: "a"))
        }
        PaperlessStubProtocol.reset([.json(#"{"detail":"boom Token secret-token"}"#, status: 500)])
        await assertFailure(.rejected(status: 500, reason: "boom Token [скрыто]")) { _ = try await self.client.status() }
        PaperlessStubProtocol.reset([Reply(fail: true)])
        await assertFailure(.unreachable("cannotConnectToHost")) { _ = try await self.client.status() }
    }

    func testHTMLResponseIsUnexpectedNotCrash() async throws {
        PaperlessStubProtocol.reset([Reply(status: 200, body: Data("<html>login</html>".utf8), headers: ["Content-Type": "text/html"])])
        await assertFailure(.unexpectedResponse) { _ = try await self.client.status() }
        PaperlessStubProtocol.reset([.json(#"{"unexpected":true}"#)])
        await assertFailure(.unexpectedResponse) { _ = try await self.client.documents(query: "", page: 1) }
    }

    func testRedirectIsNotFollowed() async throws {
        PaperlessStubProtocol.reset([Reply(redirect: URL(string: "https://evil.example/api/documents/")!)])
        do {
            _ = try await client.status()
            XCTFail("a redirect must not succeed")
        } catch let error as FilesFailure {
            XCTAssertEqual(error, .rejected(status: 302, reason: ""))
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.host, "doc.example")
    }

    func testUploadOverLimitIsRejectedBeforeRequest() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paperless-huge-\(UUID().uuidString).bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(PaperlessClient.uploadLimit) + 1)
        try handle.close()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        await assertFailure(.tooLarge) { _ = try await self.client.upload(file: url, name: "huge.bin", options: .init(title: "huge")) }
        XCTAssertEqual(requests.count, 0)
    }

    func testDocumentDetailParsesContent() async throws {
        PaperlessStubProtocol.reset([
            .json(
                #"{"id":5,"title":"Договор","content":"Текст договора\nпункт 2","original_file_name":"lease.pdf","page_count":3,"tags":[1]}"#
            )
        ])
        let detail = try await client.document(id: 5)
        XCTAssertEqual(
            detail,
            PaperlessDocumentDetail(
                id: 5, title: "Договор", content: "Текст договора\nпункт 2", originalFileName: "lease.pdf", pageCount: 3))
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://doc.example/api/documents/5/")
        PaperlessStubProtocol.reset([.json(#"{"id":6,"title":"Без текста","content":null}"#)])
        let empty = try await client.document(id: 6)
        XCTAssertEqual(empty.content, "")
        XCTAssertNil(empty.pageCount)
    }

    func testDownloadWritesOriginalToDestination() async throws {
        PaperlessStubProtocol.reset([Reply(status: 200, body: Data("%PDF-1.7 original".utf8), headers: ["Content-Type": "application/pdf"])]
        )
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("paperless-dl-\(UUID().uuidString).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        try await client.download(id: 5, original: true, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("%PDF-1.7 original".utf8))
        XCTAssertEqual(requests.first?.url?.absoluteString, "https://doc.example/api/documents/5/download/?original=true")
        XCTAssertEqual(client.documentURL(id: 5).absoluteString, "https://doc.example/documents/5/details")
    }

    private func assertFailure(
        _ expected: FilesFailure, _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as FilesFailure {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
