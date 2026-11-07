import Foundation

/// Atlassian Document Format: a text projection for display and search.
/// Task 8 adds the simplicity classifier and the builder from plain text.
public enum JiraADF {
    /// Paragraph text with hard breaks as newlines and paragraphs separated by a blank line.
    public static func text(from adf: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: adf) as? [String: Any] else { return "" }
        return text(fromNode: object)
    }

    static func text(fromNode node: [String: Any]) -> String {
        var blocks: [String] = []
        for child in node["content"] as? [[String: Any]] ?? [] { collect(child, into: &blocks, depth: 0) }
        return blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collect(_ node: [String: Any], into blocks: inout [String], depth: Int) {
        let type = node["type"] as? String ?? ""
        let children = node["content"] as? [[String: Any]] ?? []
        switch type {
        case "paragraph", "heading":
            blocks.append(inline(children))
        case "bulletList", "orderedList":
            var index = 0
            for item in children {
                index += 1
                let marker = type == "orderedList" ? "\(index). " : "• "
                var inner: [String] = []
                for child in item["content"] as? [[String: Any]] ?? [] { collect(child, into: &inner, depth: depth + 1) }
                blocks.append(String(repeating: "  ", count: depth) + marker + inner.joined(separator: "\n"))
            }
        case "codeBlock":
            blocks.append(inline(children))
        case "table":
            for row in children {
                let cells = (row["content"] as? [[String: Any]] ?? []).map { cell -> String in
                    var inner: [String] = []
                    for child in cell["content"] as? [[String: Any]] ?? [] { collect(child, into: &inner, depth: depth + 1) }
                    return inner.joined(separator: " ")
                }
                blocks.append(cells.joined(separator: " | "))
            }
        case "mediaSingle", "mediaGroup", "media":
            blocks.append("[вложение]")
        case "rule":
            blocks.append("---")
        default:
            if children.isEmpty {
                let piece = inline([node])
                if !piece.isEmpty { blocks.append(piece) }
            } else {
                for child in children { collect(child, into: &blocks, depth: depth) }
            }
        }
    }

    private static func inline(_ nodes: [[String: Any]]) -> String {
        var text = ""
        for node in nodes {
            switch node["type"] as? String ?? "" {
            case "text": text += node["text"] as? String ?? ""
            case "hardBreak": text += "\n"
            case "mention":
                let attrs = node["attrs"] as? [String: Any]
                let name = attrs?["text"] as? String ?? "@"
                text += name.hasPrefix("@") ? name : "@" + name
            case "emoji":
                text += (node["attrs"] as? [String: Any])?["text"] as? String ?? ""
            case "inlineCard":
                text += (node["attrs"] as? [String: Any])?["url"] as? String ?? ""
            default:
                text += inline(node["content"] as? [[String: Any]] ?? [])
            }
        }
        return text
    }
}

extension JiraADF {
    /// Node types Makosh can rebuild from plain text without losing anything.
    static let simpleNodes: Set<String> = ["doc", "paragraph", "text", "hardBreak", "mention", "bulletList", "orderedList", "listItem"]
    static let simpleMarks: Set<String> = ["strong", "em", "link", "underline", "strike", "code"]

    /// True when the document holds only paragraphs, text, breaks, mentions
    /// and simple lists; anything else (tables, media, panels, macros) is
    /// read-only in Makosh so the original keeps its formatting.
    public static func isSimple(_ adf: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: adf) as? [String: Any] else { return false }
        return isSimple(node: object)
    }

    private static func isSimple(node: [String: Any]) -> Bool {
        guard let type = node["type"] as? String, simpleNodes.contains(type) else { return false }
        for mark in node["marks"] as? [[String: Any]] ?? [] {
            guard let markType = mark["type"] as? String, simpleMarks.contains(markType) else { return false }
        }
        return (node["content"] as? [[String: Any]] ?? []).allSatisfy(isSimple(node:))
    }

    /// Paragraphs split at blank lines, lines inside a paragraph joined with
    /// hard breaks; `@Name` becomes a mention when `mentions` maps the name.
    public static func document(fromText text: String, mentions: [String: String] = [:]) -> Data {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var paragraphs: [[String: Any]] = []
        if !normalized.isEmpty {
            for block in normalized.components(separatedBy: "\n\n") {
                var content: [[String: Any]] = []
                for (index, line) in block.components(separatedBy: "\n").enumerated() {
                    if index > 0 { content.append(["type": "hardBreak"]) }
                    content += inlineNodes(line, mentions: mentions)
                }
                paragraphs.append(["type": "paragraph", "content": content])
            }
        }
        let doc: [String: Any] = ["type": "doc", "version": 1, "content": paragraphs]
        return (try? JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    private static func inlineNodes(_ line: String, mentions: [String: String]) -> [[String: Any]] {
        guard !mentions.isEmpty else { return line.isEmpty ? [] : [["type": "text", "text": line]] }
        var nodes: [[String: Any]] = []
        var pending = ""
        var rest = Substring(line)
        while let at = rest.firstIndex(of: "@") {
            pending += rest[..<at]
            let after = rest[rest.index(after: at)...]
            if let (name, id) = mentions.sorted(by: { $0.key.count > $1.key.count }).first(where: { after.hasPrefix($0.key) }) {
                if !pending.isEmpty { nodes.append(["type": "text", "text": pending]) }
                pending = ""
                nodes.append(["type": "mention", "attrs": ["id": id, "text": "@" + name]])
                rest = after.dropFirst(name.count)
            } else {
                pending += "@"
                rest = after
            }
        }
        pending += rest
        if !pending.isEmpty { nodes.append(["type": "text", "text": pending]) }
        return nodes
    }
}
