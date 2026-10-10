import SwiftUI
import AppKit
import MakoshTelegram

/// Reading view over captured message entities; revealing never changes the source.
struct TelegramMessageTextView<MenuContent: View>: View {
    let value: TelegramFormattedText?
    let identity: String
    var lineLimit: Int? = nil
    @ViewBuilder let menuContent: () -> MenuContent
    @State private var revealedKey: TelegramMessagePresentationKey?
    @State private var pendingLink: PendingLink?
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
    private var attributed: AttributedString? {
        guard let value else { return nil }
        let native = NSMutableAttributedString(attributedString:
            TelegramMessagePresentation.attributedString(value, revealingSpoilers: revealed))
        if !revealed {
            for entity in value.entities {
                if case .spoiler = entity.kind {
                    native.addAttribute(.link, value: Self.revealURL,
                        range: NSRange(location: entity.offset, length: entity.length))
                }
            }
        }
        return try? AttributedString(native, including: \.appKit)
    }
    private var accessibleLinks: [AccessibleLink] {
        guard let value else { return [] }
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
            if let attributed {
                Text(attributed).lineLimit(lineLimit).textSelection(.enabled)
                    .contextMenu { menuContent() }
                    .environment(\.openURL, OpenURLAction { url in activate(url); return .handled })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(value.map { TelegramMessagePresentation.plainText($0, revealingSpoilers: revealed) } ?? ""))
                    .accessibilityActions {
                        if hasSpoilers && !revealed {
                            Button("Показать скрытый текст") { revealedKey = key }
                        }
                        ForEach(accessibleLinks) { link in
                            Button("Открыть ссылку: \(link.label)") { activate(link.url) }
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
        .onChange(of: identity) { _, _ in revealedKey = nil; pendingLink = nil }
        .onChange(of: value) { _, _ in revealedKey = nil; pendingLink = nil }
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

@MainActor func telegramSourcePreview(_ source: TelegramMessageActionSource) -> String {
    guard let value = source.metadata.formattedText,
          value.text.utf8.elementsEqual(source.text.utf8) else { return "Форматирование сообщения недоступно" }
    return TelegramMessagePresentation.plainText(value)
}
