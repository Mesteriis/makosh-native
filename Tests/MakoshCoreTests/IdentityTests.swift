import XCTest
@testable import MakoshCore

final class IdentityTests: XCTestCase {
    func testComposedAndDecomposedIdentifiersRemainDistinct() {
        let composed = "é"
        let decomposed = "e\u{301}"
        XCTAssertEqual(composed, decomposed, "Swift String equality alone is unsuitable for opaque IDs")
        assertDistinct(composed, decomposed)
    }

    func testReorderedCombiningMarksRemainDistinctAtEqualUTF8Length() {
        let first = "a\u{301}\u{323}"
        let second = "a\u{323}\u{301}"
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.utf8.count, second.utf8.count)
        assertDistinct(first, second)
    }

    func testComponentBoundariesCannotCollideWithDelimitersOrEmptyValues() {
        let identities = [
            ServiceIdentity(service: "a.b", accountID: "c", externalID: "d"),
            ServiceIdentity(service: "a", accountID: "b.c", externalID: "d"),
            ServiceIdentity(service: "a", accountID: "b", externalID: "c.d"),
            ServiceIdentity(service: "", accountID: "a", externalID: "b"),
            ServiceIdentity(service: "a", accountID: "", externalID: "b"),
            ServiceIdentity(service: "a", accountID: "b", externalID: "")
        ]
        XCTAssertEqual(Set(identities).count, identities.count)
        XCTAssertEqual(Set(identities.map(\.id)).count, identities.count)
        XCTAssertTrue(identities.allSatisfy { $0.id.utf8.allSatisfy { $0 < 128 } })
    }

    func testIdenticalRawValuesHaveEqualHashAndRetainOriginalStrings() throws {
        let identity = ServiceIdentity(service: "source", accountID: "e\u{301}", externalID: "raw:./é")
        let decoded = try JSONDecoder().decode(ServiceIdentity.self, from: JSONEncoder().encode(identity))
        XCTAssertEqual(identity, decoded)
        XCTAssertEqual(identity.id, decoded.id)
        XCTAssertEqual(Set([identity, decoded]).count, 1)
        XCTAssertTrue(identity.accountID.utf8.elementsEqual(decoded.accountID.utf8))
    }

    private func assertDistinct(_ first: String, _ second: String) {
        for index in 0..<3 {
            var lhs = ["service", "account", "external"]
            var rhs = lhs
            lhs[index] = first; rhs[index] = second
            let a = ServiceIdentity(service: lhs[0], accountID: lhs[1], externalID: lhs[2])
            let b = ServiceIdentity(service: rhs[0], accountID: rhs[1], externalID: rhs[2])
            XCTAssertNotEqual(a, b)
            XCTAssertNotEqual(a.id, b.id)
            XCTAssertEqual(Set([a, b]).count, 2)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: [(a.id, "new"), (b.id, "old")]).count, 2)
        }
    }
}
