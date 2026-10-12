import AppKit
import XCTest
@testable import MakoshApp

/// Native pointer events exercise the app control without a capture device,
/// permission request, model, account or server send.
@MainActor final class TelegramRecorderInteractionTests: XCTestCase {
    func testHeldPressCreatesFloatingControlAndRemovesItAfterRelease() async throws {
        let fixture = RecorderButtonFixture()
        defer { fixture.close() }
        fixture.button.mouseDown(with: fixture.event(.leftMouseDown, at: fixture.center))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.window.childWindows?.count, 2)
        XCTAssertEqual(fixture.window.childWindows?.map(\.frame.size).filter { $0 == NSSize(width: 120, height: 120) }.count, 1)
        fixture.button.mouseUp(with: fixture.event(.leftMouseUp, at: fixture.center))
        XCTAssertEqual(fixture.releases, [true])
        XCTAssertTrue(fixture.window.childWindows?.isEmpty ?? true)
    }

    func testHeldReleaseUsesFloatingHitAreaBeyondOriginalSmallButton() async throws {
        let fixture = RecorderButtonFixture()
        defer { fixture.close() }
        fixture.button.mouseDown(with: fixture.event(.leftMouseDown, at: fixture.center))
        try await Task.sleep(for: .milliseconds(400))
        // 40pt is outside the32pt composer button and inside the120pt overlay.
        fixture.button.mouseUp(with: fixture.event(.leftMouseUp,
            at: fixture.center.applying(.init(translationX: 40, y: 0))))
        XCTAssertEqual(fixture.releases, [true])
    }

    func testFloatingHitAreaFollowsUpwardPointerUntilLock() async throws {
        let fixture = RecorderButtonFixture()
        defer { fixture.close() }
        fixture.button.mouseDown(with: fixture.event(.leftMouseDown, at: fixture.center))
        try await Task.sleep(for: .milliseconds(400))
        let moved = fixture.center.applying(.init(translationX: 40, y: 70))
        fixture.button.mouseDragged(with: fixture.event(.leftMouseDragged, at: moved))
        XCTAssertEqual(fixture.movements, [70])
        fixture.button.mouseUp(with: fixture.event(.leftMouseUp, at: moved))
        XCTAssertEqual(fixture.releases, [true])
    }

    func testMovingAwayBeforeHoldDeadlineNeverStartsCapture() async throws {
        let fixture = RecorderButtonFixture()
        defer { fixture.close() }
        fixture.button.mouseDown(with: fixture.event(.leftMouseDown, at: fixture.center))
        fixture.button.mouseDragged(with: fixture.event(.leftMouseDragged,
            at: fixture.center.applying(.init(translationX: 8, y: 0))))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fixture.starts, 0)
        XCTAssertTrue(fixture.window.childWindows?.isEmpty ?? true)
    }

    func testShortClickTogglesKindWithoutStartingCapture() async throws {
        let fixture = RecorderButtonFixture()
        defer { fixture.close() }
        var toggles = 0
        fixture.button.toggle = { toggles += 1 }
        fixture.button.mouseDown(with: fixture.event(.leftMouseDown, at: fixture.center))
        fixture.button.mouseUp(with: fixture.event(.leftMouseUp, at: fixture.center))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(toggles, 1)
        XCTAssertEqual(fixture.starts, 0)
        XCTAssertTrue(fixture.releases.isEmpty)
    }

    func testLockedOutsidePressRequestsDiscardInsteadOfSending() async throws {
        let fixture = RecorderButtonFixture()
        defer { fixture.close() }
        var sends = 0, discards = 0
        fixture.button.send = { sends += 1 }
        fixture.button.requestCancel = { discards += 1 }
        fixture.button.mouseDown(with: fixture.event(.leftMouseDown, at: fixture.center))
        try await Task.sleep(for: .milliseconds(400))
        fixture.button.locked = true
        fixture.button.updateRecordingPresentation(phase: .locked, roundVideo: false,
            level: 0, canUseOneTime: false, isOneTime: false, toggleOneTime: {})
        fixture.button.mouseUp(with: fixture.event(.leftMouseUp, at: fixture.center))
        XCTAssertEqual(fixture.window.childWindows?.count, 2)
        fixture.button.mouseDown(with: fixture.event(.leftMouseDown,
            at: fixture.center.applying(.init(translationX: 100, y: 0))))
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(discards, 1)
        // The pending confirmation keeps both capture controls alive.
        XCTAssertEqual(fixture.window.childWindows?.count, 2)
        fixture.button.mouseDown(with: fixture.event(.leftMouseDown,
            at: fixture.center.applying(.init(translationX: 40, y: 0))))
        XCTAssertEqual(sends, 1)
    }

    func testContextReplacementRemovesPanelsAndAbandonsHeldRelease() async throws {
        let fixture = RecorderButtonFixture()
        defer { fixture.close() }
        fixture.button.mouseDown(with: fixture.event(.leftMouseDown, at: fixture.center))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fixture.window.childWindows?.count, 2)
        fixture.button.updateContext(UUID())
        XCTAssertTrue(fixture.window.childWindows?.isEmpty ?? true)
        fixture.button.mouseUp(with: fixture.event(.leftMouseUp, at: fixture.center))
        XCTAssertTrue(fixture.releases.isEmpty)
    }
}

@MainActor private final class RecorderButtonFixture {
    let window: NSWindow
    let button = TelegramVoiceRecordButton.VoiceButton(frame: .init(x: 320, y: 20, width: 32, height: 32))
    var starts = 0
    var releases: [Bool] = []
    var movements: [Double] = []
    var center: NSPoint { .init(x: button.frame.midX, y: button.frame.midY) }
    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: .init(x: 300, y: 300, width: 400, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(button)
        button.updateContext(UUID())
        button.canBegin = true
        button.isEnabled = true
        button.begin = { [weak self] in self?.starts += 1 }
        button.move = { [weak self] in self?.movements.append($0) }
        button.release = { [weak self] in self?.releases.append($0) }
    }
    func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1)!
    }
    func close() {
        button.invalidateHold()
        button.removeFromSuperview()
        window.close()
    }
}
