import XCTest
import SwiftSignalKit
@testable import MakoshTelegram

@MainActor final class TelegramVoiceEligibilityRequestTests: XCTestCase {
    // Catches refusing/ignoring a current native snapshot instead of delivering
    // its actual permission result to the recording state machine.
    func testDeliversCurrentSnapshot() async {
        let request = TelegramVoiceEligibilityRequest()
        let value = await request.check(signal: .single(.allowed))
        XCTAssertEqual(value, .allowed)
    }
    // Catches a permission wait surviving navigation, or replacing a newer
    // request with an old observer's late response.
    func testCancellationResolvesWaitingSnapshotAndNewRequestIsIndependent() async {
        let request = TelegramVoiceEligibilityRequest()
        var result: TelegramVoiceEligibility?
        let waiting = Task { result = await request.check(signal: .never()) }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(result)
        request.cancel(); await waiting.value
        XCTAssertEqual(result, .unavailable)
        let next = await request.check(signal: .single(.voicePrivacy))
        XCTAssertEqual(next, .voicePrivacy)
    }
}
