import XCTest
import SwiftUI
import AppKit
import Combine
@testable import MakoshApp

@MainActor final class TelegramAppearanceTests: XCTestCase {
    func testLeavingTelegramAndUnknownThemeRestoreSystemInsteadOfRetainingOverride() {
        let cases: [(String, Bool, ColorScheme, ColorScheme)] = [
            ("classic", false, .dark, .dark), ("night", false, .light, .light),
            ("system", true, .dark, .dark), ("unknown", true, .dark, .dark),
            ("classic", true, .dark, .light), ("day", true, .dark, .light), ("night", true, .light, .dark)]
        for (theme, telegram, system, expected) in cases {
            XCTAssertEqual(telegramWorkspaceScheme(theme: theme, telegramSelected: telegram, system: system), expected)
        }
    }
    func testNativeApplicationAppearanceInitialStateAndChangesAreObserved() async {
        let app = NSApplication.shared, saved = NSApplication.shared.appearance
        defer { app.appearance = saved }
        app.appearance = NSAppearance(named: .darkAqua)
        let observer = TelegramSystemAppearance()
        XCTAssertEqual(observer.scheme, .dark)
        app.appearance = NSAppearance(named: .aqua)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while observer.scheme != .light && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(observer.scheme, .light)
        app.appearance = NSAppearance(named: .darkAqua)
        let changed = ContinuousClock.now.advanced(by: .seconds(3))
        while observer.scheme != .dark && ContinuousClock.now < changed { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(observer.scheme, .dark)
    }
}
