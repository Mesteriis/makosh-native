import AppKit
import SwiftUI
import MakoshTelegram

@MainActor struct TelegramReadingMenuAction {
    let title: String
    let enabled: Bool
    let perform: () -> Void
}

/// The installed text is the reading projection; raw source stays in the key.
@MainActor final class TelegramMessageReadingText: NSTextView, NSTextViewDelegate {
    private var source: TelegramFormattedText?
    private var sourceKey: TelegramMessagePresentationKey?
    private var sourceOffset = 0
    private var copyAllowed = false
    private var spoilersRevealed = false
    private var quoteLimit = 1024
    private var actions: [TelegramReadingMenuAction] = []
    private var quoteAction: ((TelegramReplyQuote) -> Void)?
    private var activateAction: ((URL) -> Void)?
    private var generation = UUID()
    private let customEmojiOverlay = TelegramCustomEmojiTextOverlay()
    override func layout() { super.layout(); customEmojiOverlay.layout() }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); customEmojiOverlay.layout() }
    func detachCustomEmoji() { customEmojiOverlay.detach() }
    func install(presentation: NSAttributedString, value: TelegramFormattedText,
        key: TelegramMessagePresentationKey, offset: Int = 0, canCopy: Bool,
        revealingSpoilers: Bool = false, maximumQuoteLength: Int = 1024,
        actions: [TelegramReadingMenuAction] = [], quote: ((TelegramReplyQuote) -> Void)? = nil,
        activate: ((URL) -> Void)? = nil,
        customEmojiDescriptors: [Int64: TelegramCustomEmojiDescriptor] = [:],
        customEmojiContext: TelegramCustomEmojiPlaybackContext? = nil, lineLimit: Int? = nil) {
        TelegramCustomEmojiTextSystem.install(in: self)
        let reset = sourceKey != key || source != value || sourceOffset != offset ||
            copyAllowed != canCopy || spoilersRevealed != revealingSpoilers
        generation = UUID()
        source = value; sourceKey = key; sourceOffset = offset; copyAllowed = canCopy
        spoilersRevealed = revealingSpoilers; quoteLimit = maximumQuoteLength
        self.actions = actions; quoteAction = quote; activateAction = activate
        isEditable = false; isSelectable = canCopy; isRichText = true
        importsGraphics = false; allowsUndo = false; drawsBackground = false
        textContainerInset = .zero; textContainer?.lineFragmentPadding = 0
        isHorizontallyResizable = false; isVerticallyResizable = false
        textContainer?.widthTracksTextView = true; textContainer?.heightTracksTextView = false
        textContainer?.maximumNumberOfLines = lineLimit.map { max(1, $0) } ?? 0
        textContainer?.lineBreakMode = lineLimit == nil ? .byWordWrapping : .byTruncatingTail
        isAutomaticLinkDetectionEnabled = false; isAutomaticDataDetectionEnabled = false
        isAutomaticTextReplacementEnabled = false; isContinuousSpellCheckingEnabled = false
        delegate = self
        if attributedString() != presentation {
            let previous = selectedRange()
            textStorage?.setAttributedString(presentation)
            if !reset, NSMaxRange(previous) <= presentation.length { setSelectedRange(previous) }
        }
        if reset { setSelectedRange(.init(location: 0, length: 0)) }
        setAccessibilityLabel(presentation.string)
        let concealed: [NSRange] = revealingSpoilers ? [] : value.entities.compactMap {
            if case .spoiler = $0.kind { return .init(location: $0.offset, length: $0.length) }; return nil
        }
        customEmojiOverlay.update(textView: self, value: value, descriptors: customEmojiDescriptors,
            context: customEmojiContext, concealedRanges: concealed)
    }
    func selectedQuote() -> TelegramReplyQuote? {
        guard copyAllowed, quoteAction != nil, let source, let key = sourceKey,
              sourceOffset >= 0, sourceOffset <= key.value.text.utf16.count,
              source.text.utf16.count <= key.value.text.utf16.count - sourceOffset,
              (key.value.text as NSString).substring(with: .init(location: sourceOffset, length: source.text.utf16.count)).utf8.elementsEqual(source.text.utf8) else { return nil }
        let selected = selectedRange()
        guard selected.location != NSNotFound, selected.length > 0,
              selected.location <= source.text.utf16.count,
              selected.length <= source.text.utf16.count - selected.location else { return nil }
        let range = NSRange(location: sourceOffset + selected.location, length: selected.length)
        if !spoilersRevealed && key.value.entities.contains(where: {
            if case .spoiler = $0.kind { return NSIntersectionRange(range, .init(location: $0.offset, length: $0.length)).length > 0 }; return false
        }) { return nil }
        return TelegramReplyQuote(source: key.value, selection: .init(location: range.location, length: range.length), maximumLength: quoteLimit)
    }
    func performQuote() { if let quote = selectedQuote() { quoteAction?(quote) } }
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard copyAllowed, range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= (string as NSString).length else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((string as NSString).substring(with: range), forType: .string)
    }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return copyAllowed && selectedRange().length > 0 }
        return super.validateUserInterfaceItem(item)
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL { activateAction?(url) }
        return true
    }
    override func mouseDown(with event: NSEvent) {
        guard !copyAllowed else { super.mouseDown(with: event); return }
        guard let container = textContainer, let layout = layoutManager else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < (textStorage?.length ?? 0),
              let url = textStorage?.attribute(.link, at: index, effectiveRange: nil) as? URL else { return }
        let glyphs = layout.glyphRange(forCharacterRange: .init(location: index, length: 1), actualCharacterRange: nil)
        if layout.boundingRect(forGlyphRange: glyphs, in: container).contains(point) { activateAction?(url) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { readingMenu() }
    func readingMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let request = generation
        func append(_ title: String, enabled: Bool, action: @escaping @MainActor (TelegramMessageReadingText) -> Void) {
            let handler = TelegramReadingMenuHandler { [weak self] in
                guard enabled, let self, self.generation == request else { return }; action(self)
            }
            let item = NSMenuItem(title: title, action: #selector(TelegramReadingMenuHandler.invoke(_:)), keyEquivalent: "")
            item.target = handler; item.representedObject = handler; item.isEnabled = enabled
            menu.addItem(item)
        }
        if selectedQuote() != nil { append("Цитировать", enabled: true) { $0.performQuote() } }
        if copyAllowed { append("Копировать", enabled: selectedRange().length > 0) { $0.copy(nil) } }
        if !menu.items.isEmpty && !actions.isEmpty { menu.addItem(.separator()) }
        for action in actions { append(action.title, enabled: action.enabled) { _ in action.perform() } }
        return menu
    }
}

@MainActor private final class TelegramReadingMenuHandler: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: Any?) { action() }
}

struct TelegramNativeMessageReading: NSViewRepresentable {
    let presentation: NSAttributedString
    let value: TelegramFormattedText
    let key: TelegramMessagePresentationKey
    let offset: Int
    let canCopy: Bool
    let revealingSpoilers: Bool
    let maximumQuoteLength: Int
    let actions: [TelegramReadingMenuAction]
    let quote: ((TelegramReplyQuote) -> Void)?
    let activate: (URL) -> Void
    var customEmojiDescriptors: [Int64: TelegramCustomEmojiDescriptor] = [:]
    var customEmojiContext: TelegramCustomEmojiPlaybackContext? = nil
    var lineLimit: Int? = nil
    func makeNSView(context: Context) -> TelegramMessageReadingText { TelegramMessageReadingText(frame: .zero) }
    func updateNSView(_ text: TelegramMessageReadingText, context: Context) {
        text.install(presentation: presentation, value: value, key: key, offset: offset, canCopy: canCopy,
            revealingSpoilers: revealingSpoilers, maximumQuoteLength: maximumQuoteLength,
            actions: actions, quote: quote, activate: activate,
            customEmojiDescriptors: customEmojiDescriptors, customEmojiContext: customEmojiContext, lineLimit: lineLimit)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView text: TelegramMessageReadingText, context: Context) -> CGSize? {
        let proposed = proposal.width ?? 400
        let width = proposed.isFinite ? max(1, proposed) : 400
        // SwiftUI probes several widths before placing a row. Measuring the
        // installed view changes its scroll geometry while the probe is active.
        let storage = NSTextStorage(attributedString: text.attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: .init(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = text.textContainer?.maximumNumberOfLines ?? 0
        container.lineBreakMode = text.textContainer?.lineBreakMode ?? .byWordWrapping
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        return .init(width: width, height: max(17, ceil(layout.usedRect(for: container).height)))
    }
    static func dismantleNSView(_ text: TelegramMessageReadingText, coordinator: ()) {
        text.detachCustomEmoji()
        text.delegate = nil
        if let value = try? TelegramFormattedText(text: "") {
            text.install(presentation: NSAttributedString(string: ""), value: value,
                key: .init(context: "detached", value: value), canCopy: false)
        }
    }
}
