import MakoshWhatsApp
import XCTest

@testable import MakoshApp

@MainActor final class WhatsAppVoiceRecordingModelTests: XCTestCase {
  func testDeniedConsentReportsErrorAndAllowsAnExplicitRetry() async throws {
    var attempts = 0
    let model = WhatsAppVoiceRecordingModel(
      worker: WhatsAppWorker(synthetic: true), synthetic: false,
      permission: {
        attempts += 1
        return false
      }, prepared: { _ in XCTFail("No recording was admitted") })
    model.start(account: UUID(), chat: "peer@lid")
    for _ in 0..<200 { await Task.yield() }
    XCTAssertNotNil(model.error)
    XCTAssertFalse(model.recording)
    model.start(account: UUID(), chat: "peer@lid")
    for _ in 0..<200 { await Task.yield() }
    XCTAssertEqual(attempts, 2)
  }
}
