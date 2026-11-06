import Foundation

/// Splits long text into parts of about `size` characters: paragraphs are
/// packed together, an oversized paragraph is split by lines, and a line
/// with no breaks is cut hard. Shared by the AI card and the file extractor.
public enum TextParts {
    public static let defaultSize = 3_000

    public static func split(_ text: String, size: Int = defaultSize) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, size > 0 else { return [] }
        var result: [String] = []
        var current = ""
        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            current = ""
        }
        func append(_ piece: String) {
            if current.isEmpty {
                current = piece
            } else if current.count + 2 + piece.count <= size {
                current += "\n\n" + piece
            } else {
                flush()
                current = piece
            }
        }
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            let paragraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }
            if paragraph.count <= size {
                append(paragraph)
                continue
            }
            for line in paragraph.components(separatedBy: "\n") {
                if line.count <= size {
                    append(line)
                    continue
                }
                var rest = Substring(line)
                while !rest.isEmpty {
                    flush()
                    result.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
            }
        }
        flush()
        return result
    }
}
