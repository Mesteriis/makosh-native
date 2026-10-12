import XCTest
import AppKit
import SwiftUI
import MakoshTelegram
@testable import MakoshApp

@MainActor final class TelegramMessageReadingScrollTests: XCTestCase {
    // Catches a reading row resizing its native view during a SwiftUI
    // measurement/update and returning a user's viewport to the history top.
    func testReadingMetadataUpdatesPreserveTheScrolledNativeHistoryViewport() async throws {
        let state = ReadingScrollState(), fixture = ReadingScrollFixture(state: state)
        defer { fixture.close() }
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollView)
        XCTAssertGreaterThan(scroll.documentView?.bounds.height ?? 0, 2000)
        scroll.contentView.scroll(to: .init(x: 0, y: 700))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await fixture.settle()
        let retained = scroll.contentView.bounds.minY
        XCTAssertGreaterThan(retained, 600)
        for revision in 1...4 {
            state.revision = revision
            try await fixture.settle()
            XCTAssertEqual(scroll.contentView.bounds.minY, retained, accuracy: 2,
                "Refreshing reading actions must not re-anchor an unchanged history window")
        }
    }

    // Catches a requested message focus being undone by native row layout.
    func testScrollToMessageRemainsVisibleAcrossReadingRowUpdates() async throws {
        let state = ReadingScrollState(), fixture = ReadingScrollFixture(state: state)
        defer { fixture.close() }
        try await fixture.settle()
        let scroll = try XCTUnwrap(fixture.scrollView)
        state.focusID = 48
        try await fixture.settle()
        let target = try XCTUnwrap(fixture.readingViews.first { $0.string.hasPrefix("Сообщение 48:") })
        let visible = scroll.contentView.bounds
        XCTAssertTrue(target.convert(target.bounds, to: scroll.contentView).intersects(visible),
            "The selected search result must be in the native history viewport")
        XCTAssertGreaterThan(visible.minY, 1000)
        state.revision += 1
        try await fixture.settle()
        XCTAssertTrue(target.convert(target.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds),
            "A reading-action refresh must retain the focused message")
    }
}

@MainActor private final class ReadingScrollState: ObservableObject {
    @Published var revision = 0
    @Published var focusID: Int?
}

@MainActor private struct ReadingScrollHistory: View {
    @ObservedObject var state: ReadingScrollState
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(1...50, id: \.self) { id in
                        HStack(alignment: .top) {
                            Grid(alignment: .leading, verticalSpacing: 7) {
                                GridRow { Text("Synthetic author").font(.caption) }
                                GridRow { reading(id) }
                                GridRow { Text("12:00").font(.caption) }
                            }
                            .padding(11)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            Spacer(minLength: 44)
                        }.id(id)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }
            .defaultScrollAnchor(.top)
            .onChange(of: state.focusID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
    private func reading(_ id: Int) -> some View {
        let value = try! TelegramFormattedText(text: "Сообщение \(id): синтетический текст истории с переносом строк. "
            + "Проверяем независимую высоту сообщения и сохранение позиции прокрутки.")
        return TelegramNativeMessageReading(presentation: TelegramMessagePresentation.attributedString(value),
            value: value, key: .init(context: "synthetic/\(id)", value: value), offset: 0, canCopy: true,
            revealingSpoilers: false, maximumQuoteLength: 1024,
            actions: [.init(title: "Ответить \(state.revision)", enabled: true, perform: {})], quote: { _ in }, activate: { _ in })
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor private final class ReadingScrollFixture {
    let window: NSWindow
    let host: NSHostingView<ReadingScrollHistory>
    init(state: ReadingScrollState) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: ReadingScrollHistory(state: state))
        host.frame = .init(x: 0, y: 0, width: 480, height: 320)
        window.contentView = host
        window.orderFront(nil)
    }
    var scrollView: NSScrollView? { descendants(host).compactMap { $0 as? NSScrollView }.first }
    var readingViews: [TelegramMessageReadingText] { descendants(host).compactMap { $0 as? TelegramMessageReadingText } }
    func settle() async throws {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func close() {
        for text in readingViews { text.detachCustomEmoji() }
        window.orderOut(nil); window.contentView = nil; window.close()
    }
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
