import SwiftUI
import AppKit
import MakoshTelegram

struct TelegramCodeHighlightRequest: Equatable, Sendable {
    let value: TelegramFormattedText
    let key: TelegramMessagePresentationKey
    let offset: Int
    let language: String?
    let revealingSpoilers: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        let sameLanguage: Bool
        switch (lhs.language, rhs.language) {
        case (nil, nil): sameLanguage = true
        case let (left?, right?): sameLanguage = left.utf8.elementsEqual(right.utf8)
        default: sameLanguage = false
        }
        return lhs.value == rhs.value && lhs.key.value == rhs.key.value &&
            lhs.key.context.utf8.elementsEqual(rhs.key.context.utf8) && lhs.offset == rhs.offset &&
            sameLanguage && lhs.revealingSpoilers == rhs.revealingSpoilers
    }

    fileprivate var canHighlight: Bool {
        guard !value.text.isEmpty, value.text.utf16.prefix(32769).count <= 32768,
              revealingSpoilers || !value.entities.contains(where: {
                  if case .spoiler = $0.kind { true } else { false }
              }), let language else { return false }
        let bytes = language.utf8.prefix(65)
        return !bytes.isEmpty && bytes.count <= 64 && bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }
}

@MainActor final class TelegramCodeHighlightState: ObservableObject {
    typealias Parse = @Sendable (String, String?) async -> TelegramCodeHighlight?
    private let parse: Parse
    private var generation = UUID()
    @Published private var completed: Completed?

    private struct Completed {
        let request: TelegramCodeHighlightRequest
        let highlight: TelegramCodeHighlight
    }

    init(parse: @escaping Parse = { await TelegramCodeHighlighter.highlight(source: $0, language: $1) }) {
        self.parse = parse
    }

    func load(_ request: TelegramCodeHighlightRequest) async {
        let current = UUID()
        generation = current
        completed = nil
        guard !Task.isCancelled, request.canHighlight else { return }
        let highlight = await parse(request.value.text, request.language)
        guard !Task.isCancelled, generation == current,
              let highlight, highlight.matches(request.value.text) else { return }
        completed = Completed(request: request, highlight: highlight)
    }

    func invalidate() {
        generation = UUID()
        completed = nil
    }

    func attributedString(for request: TelegramCodeHighlightRequest,
        palette: TelegramCodeHighlightPalette = .init()) -> NSAttributedString {
        let highlight = request.canHighlight && completed?.request == request ? completed?.highlight : nil
        return TelegramCodeHighlightPresentation.attributedString(request.value, highlight: highlight,
            revealingSpoilers: request.revealingSpoilers, palette: palette)
    }
}

/// Owns only the asynchronous color result. The caller retains the reference
/// header, copy control, selectable renderer, links and spoiler reveal actions.
@MainActor struct TelegramCodeHighlightView<Content: View>: View {
    let value: TelegramFormattedText
    let key: TelegramMessagePresentationKey
    let offset: Int
    let language: String?
    let revealingSpoilers: Bool
    var palette: TelegramCodeHighlightPalette = .init()
    @ViewBuilder let content: (NSAttributedString) -> Content
    @StateObject private var state = TelegramCodeHighlightState()

    private var request: TelegramCodeHighlightRequest {
        .init(value: value, key: key, offset: offset, language: language,
            revealingSpoilers: revealingSpoilers)
    }

    var body: some View {
        content(state.attributedString(for: request, palette: palette))
            .task(id: request) { await state.load(request) }
            .onDisappear { state.invalidate() }
    }
}
