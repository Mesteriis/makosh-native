import XCTest
import AppKit
import Carbon
@testable import MakoshTelegram

final class TelegramSendKeyTests: XCTestCase {
    func testEveryIndependentModifierCombinationForBothReturnKeys() {
        let bits: [NSEvent.ModifierFlags] = [.capsLock, .shift, .control, .option, .command, .numericPad, .help, .function]
        for mask in 0..<(1 << bits.count) {
            let flags = bits.enumerated().reduce(into: NSEvent.ModifierFlags()) { result, item in
                if mask & (1 << item.offset) != 0 { result.insert(item.element) }
            }
            for key in [UInt16(kVK_Return), UInt16(kVK_ANSI_KeypadEnter)] {
                let plainExpected = mask == 0 || flags == .capsLock || flags == .numericPad
                XCTAssertEqual(TelegramSendKey.enter.shouldSubmit(keyCode: key, modifiers: flags, hasMarkedText: false), plainExpected, "mask \(mask)")
                XCTAssertEqual(TelegramSendKey.commandEnter.shouldSubmit(keyCode: key, modifiers: flags, hasMarkedText: false), flags.contains(.command), "mask \(mask)")
                for mode in TelegramSendKey.allCases {
                    XCTAssertFalse(mode.shouldSubmit(keyCode: key, modifiers: flags, hasMarkedText: true))
                    XCTAssertFalse(mode.shouldSubmit(keyCode: UInt16(kVK_ANSI_A), modifiers: flags, hasMarkedText: false))
                }
            }
        }
    }

    func testDeviceDependentBitsDoNotChangePolicy() {
        let deviceBits = NSEvent.ModifierFlags(rawValue: 0xffff)
        XCTAssertTrue(TelegramSendKey.enter.shouldSubmit(keyCode: UInt16(kVK_Return), modifiers: deviceBits, hasMarkedText: false))
        XCTAssertTrue(TelegramSendKey.commandEnter.shouldSubmit(keyCode: UInt16(kVK_ANSI_KeypadEnter), modifiers: deviceBits.union(.command), hasMarkedText: false))
        XCTAssertFalse(TelegramSendKey.enter.shouldSubmit(keyCode: UInt16(kVK_Return), modifiers: [.capsLock, .numericPad], hasMarkedText: false))
    }

    func testPreferenceFallbackAndIsolatedPersistence() throws {
        XCTAssertEqual(TelegramSendKey(preferenceValue: nil), .enter)
        XCTAssertEqual(TelegramSendKey(preferenceValue: "unknown"), .enter)
        XCTAssertEqual(TelegramSendKey(preferenceValue: "enter"), .enter)
        XCTAssertEqual(TelegramSendKey(preferenceValue: "commandEnter"), .commandEnter)
        let suite = "Makosh.SendKeyTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.object(forKey: TelegramSendKey.preferenceKey))
        _ = TelegramSendKey(preferenceValue: defaults.string(forKey: TelegramSendKey.preferenceKey))
        XCTAssertNil(defaults.object(forKey: TelegramSendKey.preferenceKey), "Fallback must not write preferences")
        defaults.set(TelegramSendKey.commandEnter.rawValue, forKey: TelegramSendKey.preferenceKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(TelegramSendKey(preferenceValue: reopened.string(forKey: TelegramSendKey.preferenceKey)), .commandEnter)
    }
}
