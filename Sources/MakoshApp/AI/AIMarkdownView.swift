import AppKit
import MakoshAI
import SwiftUI

/// A model answer with its Markdown: bold, italic, inline code, links and
/// list lines inline; headings; fenced code in a monospaced, copyable block.
struct AIMarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(AIMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let value): Self.inline(value)
                case .heading(let level, let value):
                    Self.inline(value).font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                case .code(let language, let code): AICodeBlockView(language: language, code: code)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Inline Markdown keeping the answer's own line breaks and indents; plain text if it does not parse.
    static func inline(_ value: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: value, options: options) { return Text(attributed) }
        return Text(value)
    }
}

private struct AICodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "код").font(.caption2.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Скопировано" : "Копировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                .buttonStyle(.borderless).font(.caption2).accessibilityIdentifier("ai.code.copy")
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code).font(.system(.callout, design: .monospaced)).fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
        }
        .background(.black.opacity(0.25), in: .rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.08)) }
    }
}
