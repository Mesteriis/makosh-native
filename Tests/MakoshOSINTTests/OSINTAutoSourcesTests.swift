import Foundation
import MakoshCore
import XCTest

@testable import MakoshOSINT

final class OSINTAutoSourcesTests: XCTestCase {
    private let flagged = [ImportSource(service: "carddav", accountID: "acc"), ImportSource(service: "telegram", accountID: "123")]

    private func settings(enabled: Bool, trusted: Bool, installed: Bool) -> OSINTSettings {
        var settings = OSINTSettings()
        settings.enabled = enabled
        settings.hostKeyFingerprint = trusted ? "SHA256:abc" : nil
        settings.installedSHA = installed ? FlowsintPin.current.sha : nil
        return settings
    }

    func testReconcileSourcesEmptyWhenDisabled() {
        XCTAssertEqual(
            OSINTAutoSources.sources(flaggedBookSources: flagged, settings: settings(enabled: false, trusted: true, installed: true)), [])
        XCTAssertEqual(
            OSINTAutoSources.sources(flaggedBookSources: flagged, settings: settings(enabled: true, trusted: false, installed: true)), [])
        XCTAssertEqual(
            OSINTAutoSources.sources(flaggedBookSources: flagged, settings: settings(enabled: true, trusted: true, installed: false)), [])
        XCTAssertEqual(
            OSINTAutoSources.sources(flaggedBookSources: flagged, settings: settings(enabled: true, trusted: true, installed: true)),
            flagged)
        XCTAssertEqual(
            OSINTAutoSources.sources(flaggedBookSources: [], settings: settings(enabled: true, trusted: true, installed: true)), [])
    }
}
