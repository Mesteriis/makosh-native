import XCTest

@testable import MakoshOSINT

final class FlowsintPinTests: XCTestCase {
    func testPinMatchesGlobalConstraints() {
        let pin = FlowsintPin.current
        XCTAssertEqual(pin.repository, "https://github.com/reconurge/flowsint")
        XCTAssertEqual(pin.tag, "v1.2.13")
        XCTAssertEqual(pin.sha, "4c05849bc6ca5055ad187d056ef26e61b3bc2fea")
        XCTAssertEqual(pin.baseImages, ["python:3.12-slim", "node:24-alpine", "nginx:1.29-alpine"])
    }
}
