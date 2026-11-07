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
