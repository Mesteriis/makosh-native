import XCTest
@testable import MakoshApp
@testable import MakoshTelemost

extension TelemostWorkspaceModelTests {
    func testPatchReturnsExactOutcomeAndKeepsRejectedOrUnknownEdit() async throws {
        for (status, state, word) in [(200, TelemostOperationState.accepted, "подтвердил"), (403, .rejected, "отклонил"), (503, .unknown, "неизвестен")] {
            let http = TelemostScriptedHTTP([telemostJSON(telemostConferenceFixture, status: 201), telemostJSON(status == 200 ? telemostConferenceFixture : "{}", status: status)])
            let (model, _, _) = try await fixture(http: http)
            model.draft = .init(waitingRoom: .admins); await model.create(request: model.draft!)
            let meeting = try XCTUnwrap(model.meetings.first); model.selectMeeting(meeting.id)
            let accepted = await model.update(patch: .init(waitingRoom: .organization))
            XCTAssertEqual(accepted, state == .accepted)
            XCTAssertEqual(model.lastPatchResult?.state, state)
            XCTAssertEqual(model.lastPatchResult?.payload.scope, telemostTestScope)
            XCTAssertTrue(model.notice?.contains(word) == true)
            XCTAssertEqual(model.selectedMeetingID, meeting.id)
        }
    }
    func testFailedRefreshPublishesRetainedPartialCohosts() async throws {
        let page = try JSONSerialization.data(withJSONObject: ["cohosts": (0..<50).map { ["email": "person\($0)@example.test"] }])
        let changed = telemostConferenceFixture.replacingOccurrences(of: "ADMINS", with: "ORGANIZATION")
        let http = TelemostScriptedHTTP([telemostJSON(telemostConferenceFixture, status: 201), telemostJSON(changed), .init(status: 200, headers: [:], body: page), telemostJSON("{}", status: 403)])
        let (model, _, _) = try await fixture(http: http)
        model.draft = .init(waitingRoom: .admins); await model.create(request: model.draft!)
        model.selectMeeting(try XCTUnwrap(model.meetings.first?.id)); await model.refreshSelected()
        XCTAssertEqual(model.selectedMeeting?.cohosts.count, 50)
        XCTAssertEqual(model.selectedMeeting?.conference?.waitingRoom, .organization)
        XCTAssertEqual(model.selectedMeeting?.cohostsComplete, false); XCTAssertNotNil(model.error)
    }
    func testMissingRefreshPublishesUnavailableWithoutPurging() async throws {
        let http = TelemostScriptedHTTP([telemostJSON(telemostConferenceFixture, status: 201), telemostJSON("{}", status: 404)])
        let (model, _, _) = try await fixture(http: http)
        model.draft = .init(waitingRoom: .admins); await model.create(request: model.draft!)
        model.selectMeeting(try XCTUnwrap(model.meetings.first?.id)); await model.refreshSelected()
        XCTAssertEqual(model.selectedMeeting?.unavailable, true); XCTAssertNotNil(model.selectedMeeting?.conference); XCTAssertNotNil(model.error)
    }
}
