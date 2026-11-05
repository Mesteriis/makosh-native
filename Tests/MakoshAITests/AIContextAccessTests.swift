import Foundation
import MakoshCore
import XCTest
@testable import MakoshAI

final class AIContextAccessTests: XCTestCase {
    private let maria = ServiceIdentity(service: "telegram", accountID: "1", externalID: "7")
    private let ivan = ServiceIdentity(service: "telegram", accountID: "1", externalID: "8")
    private func candidate(
        _ author: ServiceIdentity?, _ text: String, outgoing: Bool = false, protected: Bool = false
    ) -> AIContextCandidate {
        AIContextCandidate(
            author: author, line: AIContextLine(author: "x", isOutgoing: outgoing, date: .now, text: text), isProtected: protected)
    }
    private func snapshot(_ access: [ServiceIdentity: AIContactAccess]) -> AIAccessSnapshot {
        AIAccessSnapshot(enabledScopes: [], contactAccess: access)
    }

    func testPrivateChatWithForbiddenContactIsUnavailable() {
        let candidates = [candidate(maria, "hi"), candidate(nil, "mine", outgoing: true)]
        XCTAssertThrowsError(try AIContextAccess.apply(candidates, privatePeer: maria, snapshot: snapshot([maria: .forbidden]))) {
            guard case .contextUnavailable? = $0 as? AIFailure else { return XCTFail("\($0)") }
        }
    }

    func testGroupHidesForbiddenAuthorsWithCount() throws {
        let candidates = [candidate(maria, "a"), candidate(ivan, "b"), candidate(maria, "c"), candidate(nil, "mine", outgoing: true)]
        let result = try AIContextAccess.apply(candidates, privatePeer: nil, snapshot: snapshot([maria: .forbidden]))
        XCTAssertEqual(result.lines.map(\.text), ["b", "mine"])
        XCTAssertEqual(result.hiddenForbidden, 2)
        XCTAssertEqual(result.hiddenProtected, 0)
    }

    func testProtectedMessagesHiddenWithCount() throws {
        let candidates = [candidate(ivan, "open"), candidate(ivan, "secret", protected: true)]
        let result = try AIContextAccess.apply(candidates, privatePeer: nil, snapshot: snapshot([:]))
        XCTAssertEqual(result.lines.map(\.text), ["open"])
        XCTAssertEqual(result.hiddenProtected, 1)
    }

    func testInheritAndAllowedPass() throws {
        let candidates = [candidate(maria, "a"), candidate(ivan, "b")]
        let result = try AIContextAccess.apply(candidates, privatePeer: maria, snapshot: snapshot([maria: .allowed, ivan: .inherit]))
        XCTAssertEqual(result.lines.map(\.text), ["a", "b"])
        XCTAssertEqual(result.hiddenForbidden, 0)
    }
}
