import XCTest
import AppKit
@testable import MakoshApp
import MakoshTelegram

@MainActor final class TelegramCodeHighlightViewTests: XCTestCase {
    // A missing publish or reconstruction of source text breaks the displayed result.
    func testFinishedNativeParseColorsExactNULUnicodeSource() async throws {
        let request = try request("let x = \"😀\"\0\r\n")
        let state = TelegramCodeHighlightState()
        await state.load(request)
        let output = state.attributedString(for: request)
        XCTAssertEqual(Array(output.string.utf8), [108,101,116,32,120,32,61,32,34,240,159,152,128,34,0,13,10])
        XCTAssertEqual(color(output), .linkColor)
        XCTAssertTrue((output.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch == true)
    }

    // A cached result must not color another message/block before its new task starts.
    func testContextAndOffsetChangeHideStoredColorsImmediately() async throws {
        let first = try request("let x = 1")
        let state = TelegramCodeHighlightState()
        await state.load(first)
        XCTAssertEqual(color(state.attributedString(for: first)), .linkColor)
        let otherContext = try request("let x = 1", context: "other-message")
        XCTAssertEqual(color(state.attributedString(for: otherContext)), .labelColor)
        let otherOffset = try request("let x = 1", offset: 40)
        XCTAssertEqual(color(state.attributedString(for: otherOffset)), .labelColor)
        let changed = try request("e\u{301}x")
        XCTAssertEqual(Array(state.attributedString(for: changed).string.utf8), [101,204,129,120])
    }

    // An old completion must not overwrite the current captured message request.
    func testNewerParseWinsWhenOldCompletionArrivesLast() async throws {
        let gate = HighlightCompletionGate()
        let state = delayedState(gate)
        let first = try request("let first = 1")
        let second = try request("// second", context: "second-message")
        let oldTask = Task { await state.load(first) }
        await gate.untilPaused(first.value.text)
        let newTask = Task { await state.load(second) }
        await gate.untilPaused(second.value.text)
        await gate.resume(second.value.text)
        await newTask.value
        XCTAssertEqual(color(state.attributedString(for: second)), .secondaryLabelColor)
        await gate.resume(first.value.text)
        await oldTask.value
        XCTAssertEqual(color(state.attributedString(for: second)), .secondaryLabelColor)
        XCTAssertEqual(state.attributedString(for: second).string, "// second")
    }

    // Task cancellation after native parsing must discard a late successful result.
    func testCancelledLoadCannotPublishLateNativeResult() async throws {
        let gate = HighlightCompletionGate()
        let state = delayedState(gate)
        let request = try request("let cancelled = 1")
        let task = Task { await state.load(request) }
        await gate.untilPaused(request.value.text)
        task.cancel()
        await gate.resume(request.value.text)
        await task.value
        XCTAssertEqual(color(state.attributedString(for: request)), .labelColor)
    }

    // Removing the view invalidates generation even if the parse ignores cancellation.
    func testDisappearInvalidationCannotPublishLateResult() async throws {
        let gate = HighlightCompletionGate()
        let state = delayedState(gate)
        let request = try request("let removed = 1")
        let task = Task { await state.load(request) }
        await gate.untilPaused(request.value.text)
        state.invalidate()
        await gate.resume(request.value.text)
        await task.value
        XCTAssertEqual(color(state.attributedString(for: request)), .labelColor)
    }

    // Hiding a spoiler must remove both secret characters and language-dependent colors.
    func testHiddenSpoilerImmediatelyDropsColorsAndNeverReusesRevealedResult() async throws {
        let shown = try request("let SECRET = 1", spoiler: true, revealing: true)
        let hidden = try request("let SECRET = 1", spoiler: true, revealing: false)
        let state = TelegramCodeHighlightState()
        await state.load(shown)
        XCTAssertEqual(color(state.attributedString(for: shown)), .linkColor)
        let immediate = state.attributedString(for: hidden)
        XCTAssertEqual(immediate.string, "let ██████ = 1")
        XCTAssertEqual(color(immediate), .labelColor)
        await state.load(hidden)
        let output = state.attributedString(for: hidden)
        XCTAssertEqual(output.string, "let ██████ = 1")
        XCTAssertEqual(color(output), .labelColor)
        XCTAssertEqual(color(output, at: 4), .secondaryLabelColor)
        XCTAssertFalse(String(describing: output).contains("SECRET"))
    }

    // The display header truncates 15 characters; parsing must receive the full alias.
    func testLongRawLanguageAliasIsNotTruncatedToHeader() async throws {
        let request = try request("if (true) return 1;", language: "gamemakerlanguage")
        let state = TelegramCodeHighlightState()
        await state.load(request)
        XCTAssertEqual(color(state.attributedString(for: request)), .linkColor)
    }

    // Theme changes recolor semantic spans at render time, without stale palette storage.
    func testCurrentPaletteRecolorsAlreadyParsedResult() async throws {
        let request = try request("let x = 1")
        let state = TelegramCodeHighlightState()
        await state.load(request)
        var palette = TelegramCodeHighlightPalette()
        palette.blue = .cyan
        XCTAssertEqual(color(state.attributedString(for: request, palette: palette)), .cyan)
        palette.blue = .magenta
        XCTAssertEqual(color(state.attributedString(for: request, palette: palette)), .magenta)
    }

    private func color(_ output: NSAttributedString, at index: Int = 0) -> NSColor? {
        output.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    private func request(_ source: String, context: String = "message", offset: Int = 0,
        language: String? = "swift", spoiler: Bool = false, revealing: Bool = false) throws -> TelegramCodeHighlightRequest {
        var entities: [TelegramTextEntity] = [.init(offset: 0, length: source.utf16.count, kind: .pre(language: language))]
        if spoiler { entities.append(.init(offset: 4, length: 6, kind: .spoiler)) }
        let value = try TelegramFormattedText(text: source, entities: entities)
        return .init(value: value, key: .init(context: context, value: value), offset: offset,
            language: language, revealingSpoilers: revealing)
    }

    private func delayedState(_ gate: HighlightCompletionGate) -> TelegramCodeHighlightState {
        TelegramCodeHighlightState { source, language in
            let result = await TelegramCodeHighlighter.highlight(source: source, language: language)
            await gate.pause(source)
            return result
        }
    }
}

private actor HighlightCompletionGate {
    private var paused: [String: CheckedContinuation<Void, Never>] = [:]
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]

    func pause(_ source: String) async {
        await withCheckedContinuation { continuation in
            paused[source] = continuation
            waiting.removeValue(forKey: source)?.resume()
        }
    }

    func untilPaused(_ source: String) async {
        guard paused[source] == nil else { return }
        await withCheckedContinuation { waiting[source] = $0 }
    }

    func resume(_ source: String) { paused.removeValue(forKey: source)?.resume() }
}
