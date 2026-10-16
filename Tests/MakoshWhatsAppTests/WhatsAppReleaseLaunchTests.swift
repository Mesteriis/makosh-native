import XCTest

@testable import MakoshApp

@MainActor final class WhatsAppReleaseLaunchTests: XCTestCase {
  func testReleaseGuardRefusesWhatsAppFlagAndMarkerBeforeOrdinaryLaunch() {
    XCTAssertFalse(
      MakoshApp.permitsOrdinaryReleaseLaunch(
        marker: nil, requiresSynthetic: false, arguments: ["app", "--whatsapp-synthetic-preview"]))
    XCTAssertFalse(
      MakoshApp.permitsOrdinaryReleaseLaunch(
        marker: "whatsapp", requiresSynthetic: false, arguments: ["app"]))
    XCTAssertFalse(
      MakoshApp.permitsOrdinaryReleaseLaunch(
        marker: nil, requiresSynthetic: true, arguments: ["app"]))
    XCTAssertTrue(
      MakoshApp.permitsOrdinaryReleaseLaunch(
        marker: nil, requiresSynthetic: false, arguments: ["app"]))
  }
}
