import SwiftUI
import AppKit
import MakoshTelegram

/// Reading view over captured message entities; revealing never changes the source.
struct TelegramMessageTextView<MenuContent: View>: View {
    @AppStorage(TelegramAppearancePreferences.preferenceKey) private var appearanceRaw = ""
    @Environment(\.colorScheme) private var colorScheme
    private var appearance: TelegramAppearancePreferences { (try? .decode(appearanceRaw)) ?? .init() }
    let value: TelegramFormattedText?
    let identity: String
    var canCopy = false
    var lineLimit: Int? = nil
    var nativeActions: [TelegramReadingMenuAction] = []
    var quoteSelection: ((TelegramReplyQuote) -> Void)? = nil
    var maximumQuoteLength = 1024
    var customEmojiDescriptors: [Int64: TelegramCustomEmojiDescriptor] = [:]
    var customEmojiContext: TelegramCustomEmojiPlaybackContext? = nil
    @ViewBuilder let menuContent: () -> MenuContent
    @State private var revealedKey: TelegramMessagePresentationKey?
    @State private var pendingLink: PendingLink?
    @State private var copiedCode: [Int: TelegramMessagePresentationKey] = [:]
    private struct PendingLink {
        let key: TelegramMessagePresentationKey
        let url: URL
    }
    private struct AccessibleLink: Identifiable {
        let id: Int
        let label: String
        let url: URL
    }
    private static var revealURL: URL { URL(string: "makosh-ui://reveal-spoiler")! }
    private var key: TelegramMessagePresentationKey? {
        value.map { TelegramMessagePresentationKey(context: identity, value: $0) }
    }
    private var revealed: Bool { key != nil && revealedKey == key }
    private var pendingURL: URL? { pendingLink?.key == key ? pendingLink?.url : nil }
    private var hasSpoilers: Bool {
        value?.entities.contains { if case .spoiler = $0.kind { true } else { false } } ?? false
    }
    private func decorated(_ value: TelegramFormattedText, presentation: NSAttributedString? = nil) -> NSAttributedString {
        let native = NSMutableAttributedString(attributedString: presentation ??
            TelegramMessagePresentation.attributedString(value, revealingSpoilers: revealed, fontSize: CGFloat(appearance.fontSize)))
        native.enumerateAttribute(.font,in:NSRange(location:0,length:native.length)) { value, range, _ in
            if let font = value as? NSFont { native.addAttribute(.font,value:NSFontManager.shared.convert(font,toSize:CGFloat(appearance.fontSize)),range:range) }
        }
        if let color = appearance.effectivePalette(isDark:colorScheme == .dark)?.text {
            native.enumerateAttribute(.foregroundColor,in:NSRange(location:0,length:native.length)) { value, range, _ in
                if let prior = value as? NSColor, prior == NSColor.labelColor { native.addAttribute(.foregroundColor,value:NSColor(telegramRGBColor(color)),range:range) }
            }
        }
        if !revealed {
            for entity in value.entities {
                if case .spoiler = entity.kind {
                    native.addAttribute(.link, value: Self.revealURL,
                        range: NSRange(location: entity.offset, length: entity.length))
                }
            }
        }
        return native
    }
    private func accessibleLinks(_ value: TelegramFormattedText) -> [AccessibleLink] {
        let presentation = TelegramMessagePresentation.attributedString(value, revealingSpoilers: revealed)
        return value.entities.enumerated().compactMap { index, entity in
            switch entity.kind {
            case .url, .email, .textURL: break
            default: return nil
            }
            guard let url = presentation.attribute(.link, at: entity.offset, effectiveRange: nil) as? URL else { return nil }
            return AccessibleLink(id: index, label: (presentation.string as NSString).substring(
                with: NSRange(location: entity.offset, length: entity.length)), url: url)
        }
    }
    var body: some View {
        Group {
            if let value, let key {
                if lineLimit != nil {
                    richText(value, limit: lineLimit)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(telegramMessageBlocks(value), id: \.range.lowerBound) { block in
                            switch block.kind {
                            case .text: richText(block.value, offset: block.range.lowerBound)
                            case let .code(language): codeBlock(block, language: language)
                            case let .quote(collapsed):
                                TelegramQuoteReadingBlock(value: block.value, key: key,
                                    isCollapsed: collapsed, revealingSpoilers: revealed, offset: block.range.lowerBound) { limit in
                                        richText(block.value, limit: limit, offset: block.range.lowerBound)
                                    }
                            }
                        }
                    }
                }
            } else {
                Label("Форматирование сообщения недоступно", systemImage: "exclamationmark.bubble")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .alert("Открыть ссылку?", isPresented: Binding(get: { pendingURL != nil }, set: { if !$0 { pendingLink = nil } }), presenting: pendingURL) { url in
            Button("Открыть") { if pendingURL == url { NSWorkspace.shared.open(url) } }
            Button("Отмена", role: .cancel) {}
        } message: { url in Text(url.absoluteString) }
        .onChange(of: identity) { _, _ in revealedKey = nil; pendingLink = nil; copiedCode = [:] }
        .onChange(of: value) { _, _ in revealedKey = nil; pendingLink = nil; copiedCode = [:] }
    }

    @ViewBuilder private func richText(_ value: TelegramFormattedText, limit: Int? = nil, offset: Int = 0,
                                      presentation: NSAttributedString? = nil) -> some View {
        let native = decorated(value, presentation: presentation)
        if let attributed = try? AttributedString(native, including: \.appKit) {
            let hasCustomEmoji = customEmojiContext != nil && value.entities.contains {
                if case .customEmoji = $0.kind { true } else { false }
            }
            let usesNativeReading = hasCustomEmoji || (limit == nil && canCopy && !nativeActions.isEmpty)
            Group {
                if usesNativeReading, let key {
                    TelegramNativeMessageReading(presentation: native, value: value, key: key, offset: offset,
                        canCopy: canCopy, revealingSpoilers: revealed, maximumQuoteLength: maximumQuoteLength,
                        actions: nativeActions, quote: quoteSelection, activate: activate,
                        customEmojiDescriptors: customEmojiDescriptors, customEmojiContext: appearance.animationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? customEmojiContext : nil, lineLimit: limit)
                } else if canCopy { Text(attributed).textSelection(.enabled) }
                else { Text(attributed).textSelection(.disabled) }
            }
            .lineLimit(limit).fixedSize(horizontal: false, vertical: true)
            .contextMenu { menuContent() }
            .environment(\.openURL, OpenURLAction { url in activate(url); return .handled })
            .accessibilityElement(children: usesNativeReading ? .contain : .ignore)
            .accessibilityLabel(Text(TelegramMessagePresentation.plainText(value, revealingSpoilers: revealed)))
            .accessibilityActions {
                if hasSpoilers && !revealed {
                    Button("Показать скрытый текст") { revealedKey = key }
                }
                ForEach(accessibleLinks(value)) { link in
                    Button("Открыть ссылку: \(link.label)") { activate(link.url) }
                }
            }
        } else {
            Label("Форматирование сообщения недоступно", systemImage: "exclamationmark.bubble")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func codeBlock(_ block: TelegramMessageBlock, language: String?) -> some View {
        let copied = copiedCode[block.range.lowerBound] == key
        let rawLanguage = language
        let language = TelegramMessagePresentation.codeLanguage(rawLanguage, in: block.value, revealingSpoilers: revealed)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard canCopy, let key else { return }
                let text = TelegramMessagePresentation.plainText(block.value, revealingSpoilers: revealed)
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(text, forType: .string) { copiedCode[block.range.lowerBound] = key }
            } label: {
                HStack(spacing: 16) {
                    Text(copied ? "Скопировано" : language ?? "Копировать").font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.caption)
                }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!canCopy)
                .background(Color.secondary.opacity(0.10))
                .help(canCopy ? "Копировать код" : "Копирование запрещено для этого сообщения")
                .accessibilityLabel(copied ? "Скопировано" : "Копировать код")
                .accessibilityIdentifier("telegram.code.copy.\(block.range.lowerBound)")
            if let key {
                TelegramCodeHighlightView(value: block.value, key: key, offset: block.range.lowerBound,
                    language: rawLanguage, revealingSpoilers: revealed) { presentation in
                        richText(block.value, offset: block.range.lowerBound, presentation: presentation)
                    }.padding(10)
            }
        }.background(Color.secondary.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    private func activate(_ url: URL) {
        guard let key else { return }
        if url == Self.revealURL { revealedKey = key }
        else if requiresConfirmation(url) { pendingLink = PendingLink(key: key, url: url) }
        else { NSWorkspace.shared.open(url) }
    }
    private func requiresConfirmation(_ url: URL) -> Bool {
        guard let value else { return true }
        let presentation = TelegramMessagePresentation.attributedString(value, revealingSpoilers: revealed)
        return value.entities.contains { entity in
            guard case let .textURL(target) = entity.kind,
                  let rendered = presentation.attribute(.link, at: entity.offset, effectiveRange: nil) as? URL,
                  rendered == url else { return false }
            let label = (value.text as NSString).substring(with: NSRange(location: entity.offset, length: entity.length))
            return label.trimmingCharacters(in: .whitespacesAndNewlines) != target
        }
    }
}

/// SwiftUI owns expansion; AppKit measures the same captured, masked text.
private struct TelegramQuoteReadingBlock<Content: View>: View {
    let value: TelegramFormattedText
    let key: TelegramMessagePresentationKey
    let isCollapsed: Bool
    let revealingSpoilers: Bool
    let offset: Int
    @ViewBuilder let content: (Int?) -> Content
    @State private var width: CGFloat = 0
    @State private var expandedKey: TelegramMessagePresentationKey?
    private var expanded: Bool { expandedKey == key }
    private var folds: Bool {
        isCollapsed && (width <= 0 || TelegramMessagePresentation.quoteNeedsExpansion(value,
            width: width, revealingSpoilers: revealingSpoilers))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            content(folds && !expanded ? 2 : nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            if folds {
                Button {
                    expandedKey = expanded ? nil : key
                } label: {
                    Label(expanded ? "Свернуть цитату" : "Развернуть цитату",
                        systemImage: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.tint)
                    .accessibilityIdentifier("telegram.quote.toggle.\(offset)")
            }
        }.padding(.vertical, 7).padding(.leading, 10).padding(.trailing, 8)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3) }
    }
}

@MainActor func telegramSourcePreview(_ source: TelegramMessageActionSource) -> String {
    if let quote = source.replyQuote { return TelegramMessagePresentation.plainText(quote.formattedText) }
    guard let value = source.metadata.formattedText,
          value.text.utf8.elementsEqual(source.text.utf8) else { return "Форматирование сообщения недоступно" }
    return TelegramMessagePresentation.plainText(value)
}
