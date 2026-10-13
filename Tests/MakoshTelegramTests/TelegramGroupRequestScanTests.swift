import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramGroupRequestScanTests: XCTestCase {
    private var basis: TelegramGroupMembershipSnapshot {
        .init(accountID: 101, peerID: 4_294_967_306, title: "Synthetic", basic: true, isCreator: true,
            canInvite: true, canManageLinks: true, canRequests: true, canHistory: false)
    }
    private func row(_ id: Int64, origin: TelegramGroupMembershipCursor? = nil) -> TelegramGroupJoinRequest {
        .init(id: id, title: "Synthetic \(id)", username: nil, date: Int32(1000-id), about: nil, origin: origin)
    }
    private func value(_ signal: Signal<TelegramGroupJoinRequest?, TelegramGroupMembershipError>) async throws -> Result<TelegramGroupJoinRequest?, TelegramGroupMembershipError> {
        let materialized: Signal<Result<TelegramGroupJoinRequest?, TelegramGroupMembershipError>, NoError> = signal |> map { .success($0) } |> `catch` { .single(.failure($0)) }
        return try await telegramDataValue(materialized, test: self)
    }
    func testAbsenceRequiresTheFinalCompleteUnfilteredPage() async throws {
        let cursor = TelegramGroupMembershipCursor.requests(date: 993, userID: 7, seen: 1)
        let result = try await value(telegramFindGroupRequest(snapshot: basis, targetID: 8) { [self] offset in
            if offset == nil { return .single(.init(snapshot: basis, requests: [row(7)], next: cursor)) }
            return .single(.init(snapshot: basis, requests: [row(8, origin: cursor)]))
        })
        XCTAssertEqual(try result.get()?.id, 8)
    }
    func testRepeatedCursorCannotClaimThatRequestWasRemoved() async throws {
        let cursor = TelegramGroupMembershipCursor.requests(date: 993, userID: 7, seen: 1)
        let result = try await value(telegramFindGroupRequest(snapshot: basis, targetID: 9) { [self] offset in
            .single(.init(snapshot: basis, requests: [row(7, origin: offset)], next: cursor))
        })
        guard case .failure = result else { return XCTFail("Overlapping native pages must fail") }
    }
    func testFailedLaterPageCannotConfirmAbsence() async throws {
        let cursor = TelegramGroupMembershipCursor.requests(date: 993, userID: 7, seen: 1)
        let result = try await value(telegramFindGroupRequest(snapshot: basis, targetID: 9) { [self] offset in
            if offset == nil { return .single(.init(snapshot: basis, requests: [row(7)], next: cursor)) }
            return .fail(.failed)
        })
        guard case .failure = result else { return XCTFail("Partial read is never absence") }
    }
}
