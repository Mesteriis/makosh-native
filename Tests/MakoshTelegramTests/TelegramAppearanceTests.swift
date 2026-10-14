import XCTest
import SwiftUI
import AppKit
import Combine
@testable import MakoshApp

@MainActor final class TelegramAppearanceTests: XCTestCase {
    func testDefaultBubblesKeepTextContrastOnLightAndDarkWallpaper() {
        for scheme:ColorScheme in [.light,.dark] {
            var environment = EnvironmentValues(); environment.colorScheme = scheme
            for accent:Color in [.white,.black,.red,.blue,.clear] {
                for outgoing in [false,true] {
                    let color = telegramDefaultBubbleColor(outgoing:outgoing,scheme:scheme,accent:accent).resolve(in:environment)
                    for wallpaper in [0.0,1.0] {
                        let alpha = Double(color.opacity)
                        let components = [color.linearRed,color.linearGreen,color.linearBlue].map { Double($0)*alpha+wallpaper*(1-alpha) }
                        let luminance = components[0]*0.2126+components[1]*0.7152+components[2]*0.0722
                        let contrast = scheme == .dark ? 1.05/(luminance+0.05) : (luminance+0.05)/0.05
                        XCTAssertGreaterThanOrEqual(contrast,4.5,"Default text is unreadable on the selected wallpaper")
                    }
                }
            }
        }
    }
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
