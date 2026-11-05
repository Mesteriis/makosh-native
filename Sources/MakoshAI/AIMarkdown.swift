import Foundation

/// A model answer split into what is drawn differently: text with inline
/// Markdown (bold, italic, inline code, links, list lines), headings and
/// fenced code blocks.
public enum AIMarkdownBlock: Equatable, Sendable {
    case text(String)
    case heading(level: Int, text: String)
    case code(language: String?, code: String)
}

public enum AIMarkdown {
    /// Blank lines separate text blocks; a fence still open at the end (an
    /// answer being streamed) is shown as code.
    public static func blocks(_ text: String) -> [AIMarkdownBlock] {
        var result: [AIMarkdownBlock] = []
        var paragraph: [Substring] = []
        var code: [Substring]?
        var language: String?
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty { result.append(.text(joined)) }
            paragraph = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") {
                    result.append(.code(language: language, code: lines.joined(separator: "\n")))
                    code = nil
                } else {
                    lines.append(line)
                    code = lines
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flush()
                let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                language = tag.isEmpty ? nil : tag
                code = []
            } else if let heading = heading(trimmed) {
                flush()
                result.append(heading)
            } else if trimmed.isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { result.append(.code(language: language, code: lines.joined(separator: "\n"))) }
        flush()
        return result
    }

    private static func heading(_ line: String) -> AIMarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }
}
