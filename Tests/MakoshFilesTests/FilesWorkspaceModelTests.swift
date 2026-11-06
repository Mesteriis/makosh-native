import Foundation
import XCTest
@testable import MakoshCore
@testable import MakoshFiles

final class CatalogueStub: FileCatalogueReading, @unchecked Sendable {
    private let lock = NSLock()
    var items: [FileCatalogueItem] = []
    private(set) var calls = 0
    var failure: FilesFailure?
    func refresh(resolver: (any FileSourceResolving)?) async throws -> [FileCatalogueItem] {
        try lock.withLock {
            calls += 1
            if let failure { throw failure }
            return items
        }
    }
    var refreshCount: Int { lock.withLock { calls } }
}

@MainActor final class FilesWorkspaceModelTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private let keychain = MemoryKeychain()
    private var vault: FileStorageTokenVault!
    private var registry: FileStorageRegistry!
    private var journal: URL!
    private let catalogue = CatalogueStub()
    private var scripts: [UUID: PaperlessScript] = [:]
    private let a = PaperlessConnection(name: "A", baseURL: URL(string: "https://a.example")!)
    private let b = PaperlessConnection(name: "B", baseURL: URL(string: "https://b.example")!)

    override func setUp() async throws {
        suite = "makosh.files.model." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
        vault = FileStorageTokenVault(access: keychain.access)
        registry = FileStorageRegistry(defaults: defaults, vault: vault)
        journal = FileManager.default.temporaryDirectory.appendingPathComponent("files-model-\(UUID().uuidString).json")
        scripts = [a.id: PaperlessScript(), b.id: PaperlessScript()]
        try await registry.save(.paperless(a), token: "ta")
        try await registry.save(.paperless(b), token: "tb")
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: journal)
        super.tearDown()
    }
    private func model(pollInterval: Duration = .seconds(30)) -> FilesWorkspaceModel {
        let scripts = scripts
        let factory: PaperlessSender.ClientFactory = { connection, _ in scripts[connection.id]! }
        let sender = PaperlessSender(registry: registry, vault: vault, journal: journal, clientFactory: factory)
        return FilesWorkspaceModel(
            catalogue: catalogue, registry: registry, vault: vault, sender: sender, resolver: nil, clientFactory: factory,
            pollInterval: pollInterval)
    }
    private func item(
        _ name: String, service: String = "telegram", date: TimeInterval, kind: String = "document", source: String? = nil
    ) -> FileCatalogueItem {
        let hash = String(repeating: "ab", count: 32), id = UUID()
        let record = ArchiveFileRecord(
            id: id, identity: .init(service: service, accountID: "1", conversationID: "c", messageID: name),
            attachment: .init(id: name, kind: kind, name: name, size: 1), objectKey: "vaults/x/files/\(id)", storageID: hash,
            receipt: ArchiveFileEnvelopeReceipt(byteCount: 2, sha256: hash, plaintextByteCount: 1, plaintextSHA256: hash),
            capturedAt: Date(timeIntervalSince1970: date), state: .stored, purpose: nil)
        return FileCatalogueItem(record: record, messageDate: nil, author: nil, sourceTitle: source)
    }

    func testVisibleFiltersBySearchCategoryAndSort() async {
        catalogue.items = [
            item("Счёт.pdf", date: 10, source: "ООО Свет"), item("фото.jpg", date: 30, kind: "photo"), item("Договор.docx", date: 20),
        ]
        let model = model()
        await model.refresh()
        XCTAssertEqual(model.visible.map(\.name), ["фото.jpg", "Договор.docx", "Счёт.pdf"])
        model.sort = .name
        XCTAssertEqual(model.visible.map(\.name), ["Договор.docx", "Счёт.pdf", "фото.jpg"])
        model.category = .document
        XCTAssertEqual(model.visible.map(\.name), ["Договор.docx", "Счёт.pdf"])
        model.search = "СВЕТ"
        XCTAssertEqual(model.visible.map(\.name), ["Счёт.pdf"], "search matches the source title, case and ё insensitive")
        model.search = "счет"
        XCTAssertEqual(model.visible.map(\.name), ["Счёт.pdf"])
        model.category = nil
        model.search = "фот"
        XCTAssertEqual(model.visible.map(\.name), ["фото.jpg"])
    }

    func testServiceSourceShowsOnlyThatService() async {
        catalogue.items = [item("a.pdf", service: "mail", date: 1), item("b.pdf", service: "telegram", date: 2)]
        let model = model()
        await model.refresh()
        model.source = .service("mail")
        XCTAssertEqual(model.visible.map(\.name), ["a.pdf"])
        model.source = .storage(a.id)
        XCTAssertEqual(model.visible, [])
        model.source = .all
        XCTAssertEqual(model.visible.count, 2)
    }

    func testCatalogueFailureIsShownNotSwallowed() async {
        catalogue.failure = .integrity
        let model = model()
        await model.refresh()
        XCTAssertEqual(model.error, FilesFailure.integrity.errorDescription)
        XCTAssertEqual(model.items, [])
    }

    func testStorageSourceLoadsDocumentsAndPages() async throws {
        let script = scripts[a.id]!
        let first = (1...50).map {
            PaperlessDocument(id: $0, title: "d\($0)", created: nil, documentType: nil, tags: [], originalFileName: nil)
        }
        script.pages = [
            1: .init(items: first, hasMore: true),
            2: .init(
                items: [.init(id: 51, title: "d51", created: nil, documentType: nil, tags: [], originalFileName: nil)], hasMore: false),
        ]
        let model = model()
        model.source = .storage(a.id)
        await model.waitForDocuments()
        XCTAssertEqual(model.documents.count, 50)
        XCTAssertTrue(model.hasMoreDocuments)
        await model.loadMoreDocuments()
        XCTAssertEqual(model.documents.map(\.id).last, 51)
        XCTAssertFalse(model.hasMoreDocuments)
        await model.searchDocuments("счёт")
        XCTAssertEqual(model.documentQuery, "счёт")
        XCTAssertEqual(script.documentCalls.map { "\($0.query)/\($0.page)" }, ["/1", "/2", "счёт/1"])
    }

    func testLateDocumentsResultForPreviousStorageIsDropped() async throws {
        let slow = scripts[a.id]!, fast = scripts[b.id]!
        slow.holdDocuments = true
        slow.pages = [
            1: .init(
                items: [.init(id: 1, title: "from A", created: nil, documentType: nil, tags: [], originalFileName: nil)], hasMore: false)
        ]
        fast.pages = [
            1: .init(
                items: [.init(id: 2, title: "from B", created: nil, documentType: nil, tags: [], originalFileName: nil)], hasMore: false)
        ]
        let model = model()
        model.source = .storage(a.id)
        while slow.documentCalls.isEmpty { await Task.yield() }
        model.source = .storage(b.id)
        await model.waitForDocuments()
        XCTAssertEqual(model.documents.map(\.title), ["from B"])
        slow.release()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.documents.map(\.title), ["from B"], "the late page for A never lands under B")
    }

    func testTestConnectionRecordsStatusOrFailure() async throws {
        scripts[a.id]!.statusResult = .success(PaperlessStatus(documentCount: 1115, version: "3.0.5"))
        scripts[b.id]!.statusResult = .failure(.unauthorized)
        let model = model()
        await model.test(a.id)
        await model.test(b.id)
        XCTAssertEqual(model.storageStatus[a.id], .success(PaperlessStatus(documentCount: 1115, version: "3.0.5")))
        XCTAssertEqual(model.storageStatus[b.id], .failure(.unauthorized))
        try await vault.remove(connectionID: a.id)
        await model.test(a.id)
        XCTAssertEqual(model.storageStatus[a.id], .failure(.unauthorized), "a missing token is reported like a rejected one")
    }

    func testSendToRemovedConnectionFailsAndSubmissionsFollow() async throws {
        let model = model()
        let handoff = FileHandoff(name: "a.pdf") { url in try Data("x".utf8).write(to: url) }
        try await registry.remove(a.id)
        model.reloadConnections()
        XCTAssertEqual(model.connections.map(\.id), [b.id])
        let result = await model.send(handoff, to: a.id, options: .init(title: "a"))
        XCTAssertEqual(result.state, .failed(reason: FilesFailure.storageMissing.errorDescription!))
        XCTAssertEqual(model.submissions.map(\.state), [result.state])
    }

    func testRefreshProbesEachStorageOnce() async throws {
        scripts[a.id]!.statusResult = .success(PaperlessStatus(documentCount: 7, version: nil))
        scripts[b.id]!.statusResult = .failure(.unreachable("cannotConnectToHost"))
        let model = model()
        await model.refresh()
        XCTAssertEqual(model.storageStatus[a.id], .success(PaperlessStatus(documentCount: 7, version: nil)))
        XCTAssertEqual(model.storageStatus[b.id], .failure(.unreachable("cannotConnectToHost")))
        scripts[a.id]!.statusResult = .success(PaperlessStatus(documentCount: 8, version: nil))
        await model.refresh()
        XCTAssertEqual(model.storageStatus[a.id]?.map(\.documentCount), .success(7), "a known status is not probed again by polling")
    }

    func testLeavingAStorageResetsLoadingDocuments() async throws {
        let slow = scripts[a.id]!
        slow.holdDocuments = true
        let model = model()
        model.source = .storage(a.id)
        while slow.documentCalls.isEmpty { await Task.yield() }
        XCTAssertTrue(model.loadingDocuments)
        model.source = .all
        XCTAssertFalse(model.loadingDocuments, "nothing is loading for the catalogue")
        slow.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(model.loadingDocuments)
    }

    func testCorruptJournalIsReportedOnRefresh() async throws {
        try Data("not json".utf8).write(to: journal)
        let model = model()
        await model.refresh()
        XCTAssertEqual(model.error, "Журнал отправок повреждён и начат заново.")
    }

    func testPollingRefreshesWhileActiveOnly() async throws {
        let model = model(pollInterval: .milliseconds(5))
        model.startPolling()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThanOrEqual(catalogue.refreshCount, 2)
        model.stopPolling()
        try await Task.sleep(for: .milliseconds(20))
        let settled = catalogue.refreshCount
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(catalogue.refreshCount, settled)
    }
}
