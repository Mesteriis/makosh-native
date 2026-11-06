import Foundation
import XCTest
@testable import MakoshFiles

/// A scripted Paperless: uploads answer in order, task queries answer in order.
final class PaperlessScript: PaperlessServing, @unchecked Sendable {
    private let lock = NSLock()
    var uploads: [Result<String, FilesFailure>] = []
    var tasks: [Result<PaperlessTaskState, FilesFailure>] = []
    private(set) var uploadCalls: [(name: String, options: PaperlessUpload, bytes: Int)] = []
    private(set) var taskCalls: [String] = []
    var statusResult: Result<PaperlessStatus, FilesFailure> = .success(PaperlessStatus(documentCount: 0, version: nil))
    var pages: [Int: PaperlessPage<PaperlessDocument>] = [:]
    var tagList: [PaperlessNamed] = []
    var typeList: [PaperlessNamed] = []
    /// When set, `documents` waits here until `release()`.
    private var gate: CheckedContinuation<Void, Never>?
    var holdDocuments = false
    private(set) var documentCalls: [(query: String, page: Int)] = []
    func release() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { gate = nil }
            return gate
        }
        pending?.resume()
    }

    func upload(file: URL, name: String, options: PaperlessUpload) async throws -> String {
        let bytes = (try? Data(contentsOf: file))?.count ?? -1
        return try lock.withLock {
            uploadCalls.append((name, options, bytes))
            guard !uploads.isEmpty else { throw FilesFailure.unexpectedResponse }
            return try uploads.removeFirst().get()
        }
    }
    func task(id: String) async throws -> PaperlessTaskState {
        try lock.withLock {
            taskCalls.append(id)
            guard !tasks.isEmpty else { throw FilesFailure.unexpectedResponse }
            return try tasks.removeFirst().get()
        }
    }
    func status() async throws -> PaperlessStatus { try lock.withLock { statusResult }.get() }
    func tags() async throws -> [PaperlessNamed] { lock.withLock { tagList } }
    func documentTypes() async throws -> [PaperlessNamed] { lock.withLock { typeList } }
    func documents(query: String, page: Int) async throws -> PaperlessPage<PaperlessDocument> {
        let hold = lock.withLock { () -> Bool in
            documentCalls.append((query, page))
            return holdDocuments
        }
        if hold { await withCheckedContinuation { continuation in lock.withLock { gate = continuation } } }
        return lock.withLock { pages[page] } ?? .init(items: [], hasMore: false)
    }
    func download(id: Int, original: Bool, to destination: URL) async throws {}
    var details: [Int: PaperlessDocumentDetail] = [:]
    func document(id: Int) async throws -> PaperlessDocumentDetail {
        guard let detail = lock.withLock({ details[id] }) else { throw FilesFailure.unexpectedResponse }
        return detail
    }
    nonisolated func documentURL(id: Int) -> URL { URL(string: "https://doc.example/documents/\(id)/details")! }
}

final class PaperlessSenderTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let keychain = MemoryKeychain()
    private var vault: FileStorageTokenVault!
    private var registry: FileStorageRegistry!
    private var journal: URL!
    private let script = PaperlessScript()
    private let connection = PaperlessConnection(name: "Docs", baseURL: URL(string: "https://doc.example")!, defaultTags: [1])
    /// Fake clock: sleeps return at once and add up.
    private let slept = SleptTime()
    final class SleptTime: @unchecked Sendable {
        private let lock = NSLock()
        private var total: Duration = .zero
        func add(_ value: Duration) { lock.withLock { total += value } }
        var value: Duration { lock.withLock { total } }
    }
    /// Values collected from `@Sendable` callbacks.
    final class Collector<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ value: T) { lock.withLock { items.append(value) } }
        var values: [T] { lock.withLock { items } }
    }

    override func setUp() async throws {
        suite = "makosh.files.sender." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        vault = FileStorageTokenVault(access: keychain.access)
        registry = FileStorageRegistry(defaults: defaults, vault: vault)
        journal = FileManager.default.temporaryDirectory.appendingPathComponent("paperless-journal-\(UUID().uuidString).json")
        try await registry.save(.paperless(connection), token: "t")
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: journal)
        super.tearDown()
    }
    private func sender() -> PaperlessSender {
        let script = script
        return PaperlessSender(
            registry: registry, vault: vault, journal: journal, clientFactory: { _, _ in script },
            sleep: { [slept] duration in slept.add(duration) })
    }
    private var handoff: FileHandoff {
        FileHandoff(name: "Счёт.pdf", byteCount: 5, date: Date(timeIntervalSince1970: 1_700_000_000)) { url in
            try Data("%PDF-".utf8).write(to: url)
        }
    }
    private var options: PaperlessUpload { PaperlessUpload(title: "Счёт", created: nil, documentType: nil, tags: [1]) }

    func testSendUploadsPollsAndRecordsAccepted() async throws {
        script.uploads = [.success("t1")]
        script.tasks = [.success(.pending), .success(.started), .success(.success(documentID: 5))]
        let sender = sender()
        let seen = Collector<PaperlessSubmission.State>()
        let result = await sender.send(handoff, to: connection.id, options: options) { seen.append($0.state) }
        XCTAssertEqual(result.state, .accepted(documentID: 5))
        XCTAssertEqual(result.taskID, "t1")
        XCTAssertEqual(result.fileName, "Счёт.pdf")
        XCTAssertEqual(seen.values, [.uploading, .processing, .accepted(documentID: 5)], "only real changes are journaled")
        XCTAssertEqual(script.uploadCalls.map(\.bytes), [5])
        XCTAssertEqual(script.uploadCalls.first?.options, options)
        let stored = try JSONDecoder().decode([PaperlessSubmission].self, from: Data(contentsOf: journal))
        XCTAssertEqual(stored.map(\.state), [.accepted(documentID: 5)])
        let submissions = await sender.submissions()
        XCTAssertEqual(submissions, stored)
    }

    func testDuplicateFailureBecomesDuplicateState() async throws {
        script.uploads = [.success("t1")]
        script.tasks = [.success(.failure(message: "Not consuming Счёт.pdf: It is a duplicate of Счёт.pdf (#120)"))]
        let result = await sender().send(handoff, to: connection.id, options: options) { _ in }
        XCTAssertEqual(result.state, .duplicate(existingID: 120))
    }

    func testUnreachableBeforeTheBodyLeftIsFailedNotUnknown() async throws {
        for code in [
            "cannotConnectToHost", "cannotFindHost", "notConnectedToInternet", "secureConnectionFailed", "serverCertificateUntrusted",
        ] {
            script.uploads = [.failure(.unreachable(code))]
            let result = await sender().send(handoff, to: connection.id, options: options) { _ in }
            XCTAssertEqual(result.state, .failed(reason: FilesFailure.unreachable(code).errorDescription!), code)
        }
    }

    func testSendUsesTheGivenSubmissionID() async throws {
        script.uploads = [.success("t1")]
        script.tasks = [.success(.success(documentID: 5))]
        let id = UUID()
        let result = await sender().send(handoff, to: connection.id, options: options, id: id) { _ in }
        XCTAssertEqual(result.id, id)
    }

    func testUnreachableAfterUploadIsUnknownAndNeverResent() async throws {
        script.uploads = [.failure(.unreachable("timedOut"))]
        let sender = sender()
        let result = await sender.send(handoff, to: connection.id, options: options) { _ in }
        XCTAssertEqual(result.state, .unknown)
        XCTAssertNil(result.taskID)
        XCTAssertEqual(script.uploadCalls.count, 1)
        let checked = await sender.check(result.id)
        XCTAssertEqual(checked?.state, .unknown, "a check without a task ID cannot resolve and never uploads again")
        XCTAssertEqual(script.uploadCalls.count, 1)
    }

    func testPollLimitLeavesProcessingWithTaskID() async throws {
        script.uploads = [.success("t1")]
        script.tasks = Array(repeating: .success(.pending), count: 200)
        let result = await sender().send(handoff, to: connection.id, options: options) { _ in }
        XCTAssertEqual(result.state, .processing)
        XCTAssertEqual(result.taskID, "t1")
        XCTAssertEqual(slept.value, PaperlessSender.pollLimit)
        XCTAssertEqual(script.taskCalls.count, Int(PaperlessSender.pollLimit / PaperlessSender.pollInterval) + 1)
    }

    func testResumeRequeriesProcessingAfterRestart() async throws {
        let pending = PaperlessSubmission(
            id: UUID(), connectionID: connection.id, fileName: "a.pdf", title: "a", taskID: "old", state: .processing,
            startedAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        try JSONEncoder().encode([pending]).write(to: journal)
        script.tasks = [.success(.success(documentID: 9))]
        let sender = sender()
        await sender.resume()
        let submissions = await sender.submissions()
        XCTAssertEqual(submissions.map(\.state), [.accepted(documentID: 9)])
        XCTAssertEqual(script.taskCalls, ["old"])
        XCTAssertEqual(script.uploadCalls.count, 0)
    }

    func testCorruptJournalDoesNotCrashAndStartsEmpty() async throws {
        try Data("not json".utf8).write(to: journal)
        let sender = sender()
        let submissions = await sender.submissions()
        XCTAssertEqual(submissions, [])
        let failure = await sender.lastJournalFailure
        XCTAssertNotNil(failure)
    }

    func testMissingTokenFailsBeforeExport() async throws {
        try await vault.remove(connectionID: connection.id)
        let produced = Collector<Bool>()
        let handoff = FileHandoff(name: "a.pdf") { _ in produced.append(true) }
        let result = await sender().send(handoff, to: connection.id, options: options) { _ in }
        XCTAssertEqual(result.state, .failed(reason: FilesFailure.unauthorized.errorDescription!))
        XCTAssertEqual(produced.values, [])
        XCTAssertEqual(script.uploadCalls.count, 0)
        let missing = await sender().send(handoff, to: UUID(), options: options) { _ in }
        XCTAssertEqual(missing.state, .failed(reason: FilesFailure.storageMissing.errorDescription!))
    }

    func testFailedExportIsFailedNotUnknown() async throws {
        let handoff = FileHandoff(name: "a.pdf") { _ in throw FilesFailure.integrity }
        let result = await sender().send(handoff, to: connection.id, options: options) { _ in }
        XCTAssertEqual(result.state, .failed(reason: FilesFailure.integrity.errorDescription!))
        XCTAssertEqual(script.uploadCalls.count, 0)
    }
}
