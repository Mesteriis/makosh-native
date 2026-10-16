import XCTest
@testable import MakoshApp
@testable import MakoshTelemost

@MainActor final class TelemostWorkspaceModelTests: XCTestCase {
    func fixture(http: any TelemostHTTPTransport) async throws -> (TelemostWorkspaceModel, TelemostWorker, TelemostTestDatabase) {
        let db = try TelemostTestDatabase(); addTeardownBlock { try db.cleanup() }
        let repo = TelemostRepository(keyProvider: telemostTestKey)
        let worker = TelemostWorker(repository: repo, api: TelemostAPI(transport: http, clock: TelemostTestClock()),
            oauth: TelemostOAuth(transport: TelemostScriptedHTTP([telemostJSON(telemostTokenFixture), telemostJSON(telemostUserFixture)])), vault: TelemostMemoryVault())
        try await worker.open(configuration: db.configuration); try await worker.addAccount(telemostTestAccount)
        let request = try await worker.authorize(accountID: telemostTestAccountID, mode: .browserCallback)
        let grant = try await worker.completeAuthorization(id: request.id, callback: telemostCallback(request))
        try await worker.confirmGrant(grant, accountID: telemostTestAccountID)
        let model = TelemostWorkspaceModel(service: worker, opener: { _ in false })
        await model.start(configuration: db.configuration); await model.selectAccount(telemostTestAccountID)
        addTeardownBlock { await worker.close() }
        return (model, worker, db)
    }
    func testAcceptedReceiptClearsOnlyMatchingDraftRevision() async throws {
        let (model, _, _) = try await fixture(http: TelemostScriptedHTTP([telemostJSON(telemostConferenceFixture, status: 201)]))
        model.draft = .init(waitingRoom: .admins)
        await model.create(request: model.draft!)
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.snapshot.operations.first?.state, .accepted)
    }
    func testEditedDraftSurvivesSuspendedCreate() async throws {
        let http = TelemostPausedAPI(), (model, _, _) = try await fixture(http: http)
        model.draft = .init(waitingRoom: .admins)
        let work = Task { await model.create(request: model.draft!) }; await http.wait()
        model.draft = .init(waitingRoom: .organization); await http.finish(); await work.value
        XCTAssertEqual(model.draft?.waitingRoom, .organization)
        XCTAssertEqual(model.snapshot.operations.first?.state, .accepted)
    }
    func testAccountAndSelectionFenceSuspendedWork() async throws {
        let http = TelemostPausedAPI(), (model, _, _) = try await fixture(http: http)
        model.draft = .init(waitingRoom: .admins)
        let work = Task { await model.create(request: model.draft!) }; await http.wait()
        await model.selectAccount(nil); model.selectMeeting(nil)
        await http.finish(); await work.value
        XCTAssertNil(model.selectedAccountID); XCTAssertNil(model.selectedMeetingID)
        XCTAssertNil(model.notice)
    }
    func testUnknownPreservesDraftAndStatus() async throws {
        let (model, _, _) = try await fixture(http: TelemostScriptedHTTP([telemostJSON("{}", status: 201)]))
        model.draft = .init(waitingRoom: .admins); await model.create(request: model.draft!)
        XCTAssertEqual(model.draft?.waitingRoom, .admins)
        XCTAssertEqual(model.snapshot.operations.first?.state, .unknown)
    }
    func testLocalCatalogueAndPaging() async throws {
        let (model, _, _) = try await fixture(http: TelemostScriptedHTTP([]))
        await model.addLink("https://telemost.yandex.ru/j/local-test")
        XCTAssertEqual(model.meetings.count, 1); XCTAssertNotNil(model.selectedMeetingID)
    }
    func testOpenerSuccessDoesNotClaimCallConnection() async throws {
        let (base, worker, _) = try await fixture(http: TelemostScriptedHTTP([]))
        var opened: [URL] = []
        let model = TelemostWorkspaceModel(service: worker, opener: { opened.append($0); return true })
        model.openMeeting("https://telemost.yandex.ru/j/valid")
        model.openMeeting("https://telemost.yandex.ru.evil/j/valid")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://telemost.yandex.ru/j/valid"])
        XCTAssertEqual(model.lastOpenedURL?.absoluteString, "https://telemost.yandex.ru/j/valid")
        XCTAssertTrue(model.notice?.contains("браузер") == true)
        XCTAssertEqual(base.snapshot.connections[telemostTestAccountID], .authorized)
    }
}
