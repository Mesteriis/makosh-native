import CryptoKit
import Foundation
import MakoshCore

/// Turns admitted archive items into searchable chunks: overlapping windows
/// of neighbouring chat messages, and letters split into parts that each
/// repeat the letter's headers. Admission is decided per message, so a
/// forbidden author drops out of a window without dropping the window.
enum AIChunker {
    static let windowSize = 8
    static let step = 6
    static let maxCharacters = 1500

    static func chunks(_ items: [AIIndexItem], generation: Int64, admits: (AIIndexItem) -> Bool) -> [AIChunk] {
        var result: [AIChunk] = []
        var seen = Set<String>()
        // Only the newest version of each message in this batch is chunked.
        let latest = Dictionary(grouping: items, by: \.identity).compactMap { $0.value.max { $0.sequence < $1.sequence } }
        let admitted = latest.filter { !$0.removed && !$0.text.isEmpty && admits($0) }
        let byScope = Dictionary(grouping: admitted, by: \.scope)
        for scope in byScope.keys.sorted(by: { "\($0)" < "\($1)" }) {
            let group = byScope[scope, default: []].sorted { $0.sequence < $1.sequence }
            let made: [AIChunk]
            if case .mailAccount = scope {
                made = group.flatMap { letter($0, generation: generation) }
            } else {
                made = windows(group, generation: generation)
            }
            for chunk in made where seen.insert(chunk.id).inserted { result.append(chunk) }
        }
        return result
    }

    private static func windows(_ items: [AIIndexItem], generation: Int64) -> [AIChunk] {
        var result: [AIChunk] = []
        var start = 0
        while start < items.count {
            var window: [AIIndexItem] = []
            var length = 0
            for item in items[start...] {
                let line = self.line(item)
                if window.count == windowSize || (!window.isEmpty && length + line.count > maxCharacters) { break }
                window.append(item)
                length += line.count + 1
            }
            if window.count == 1, length > maxCharacters + 1 {
                result += parts(of: line(window[0]), header: "").enumerated().map { index, text in
                    chunk(window, text: text, part: index, generation: generation)
                }
            } else {
                result.append(chunk(window, text: window.map(line).joined(separator: "\n"), part: 0, generation: generation))
            }
            if start + window.count >= items.count { break }
            // Consecutive windows share their last two messages as context.
            start += window.count > windowSize - step ? window.count - (windowSize - step) : window.count
        }
        return result
    }

    private static func letter(_ item: AIIndexItem, generation: Int64) -> [AIChunk] {
        let date = item.date.formatted(.iso8601.year().month().day())
        let header = "Тема: \(item.title)\nОт: \(item.isOutgoing ? "вы" : item.author?.externalID ?? "")\nДата: \(date)\n\n"
        return parts(of: item.text, header: header).enumerated().map { index, text in
            chunk([item], text: text, part: index, generation: generation)
        }
    }

    private static func line(_ item: AIIndexItem) -> String {
        "[\(item.date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)))] \(item.isOutgoing ? "Вы" : "Собеседник"): \(item.text)"
    }

    private static func parts(of text: String, header: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            var piece = rest.prefix(maxCharacters)
            if piece.count == maxCharacters, let space = piece.lastIndex(where: \.isWhitespace),
                piece.distance(from: piece.startIndex, to: space) > maxCharacters / 2
            {
                piece = rest[rest.startIndex..<space]
            }
            result.append(header + piece)
            rest = rest[piece.endIndex...].drop(while: \.isWhitespace)
        }
        return result
    }

    private static func chunk(_ items: [AIIndexItem], text: String, part: Int, generation: Int64) -> AIChunk {
        var hash = SHA256()
        hash.update(data: Data("\(generation)|\(part)|".utf8))
        for item in items {
            let i = item.identity
            hash.update(data: Data("\(i.service.utf8.count):\(i.service)\(i.accountID.utf8.count):\(i.accountID)".utf8))
            hash.update(data: Data("\(i.conversationID.utf8.count):\(i.conversationID)\(i.messageID.utf8.count):\(i.messageID)".utf8))
        }
        hash.update(data: Data(text.utf8))
        let id = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let authors = items.filter { !$0.isOutgoing }.compactMap(\.author)
        return AIChunk(
            id: id, scope: items[0].scope, messages: items.map(\.identity), authors: Array(Set(authors)).sorted { $0.id < $1.id },
            text: text, date: items.map(\.date).max() ?? items[0].date, title: items[0].title)
    }
}
