import Foundation

public struct TelegramHistoryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let messages: [TelegramMessage]
    public var isAlbum: Bool { messages.count > 1 }
    public var visualCaption: TelegramMessage? {
        isVisualAlbum ? messages.first(where: { !$0.text.isEmpty }) : nil
    }
    public var visualCaptionAboveMedia: Bool {
        visualCaption != nil && messages.first?.captionAboveMedia == true
    }
    public var isVisualAlbum: Bool {
        isAlbum && messages.allSatisfy {
            $0.attachments.count == 1 && ($0.attachments[0].kind == .photo || $0.attachments[0].playback == .video)
        }
    }
    public static func project(_ messages: [TelegramMessage], accountID: Int64, chatID: Int64) -> [Self] {
        let occurrences = Dictionary(grouping: messages, by: \.id).mapValues(\.count)
        var rows: [(position: Int, item: Self)] = []
        var pending: [(Int, TelegramMessage)] = [], pendingKey: GroupKey?
        func flush() {
            guard let last = pending.last, let key = pendingKey else { return }
            let members = pending.map(\.1)
            rows.append((last.0, .init(id: members.count > 1 ? key.id : members[0].id, messages: members)))
            pending.removeAll(); pendingKey = nil
        }
        for (position, message) in messages.enumerated() {
            if occurrences[message.id] == 1, message.canGroupMedia, !message.attachments.isEmpty,
               !message.attachments.contains(where: { $0.kind == .unsupported }),
               let group = message.albumGroupID, let metadata = message.actionMetadata {
                let key = GroupKey(accountID: accountID, chatID: chatID, peerID: metadata.peerID,
                    namespace: metadata.namespace, threadID: metadata.threadID, groupID: group)
                // Ordinary rows do not flush a pending group. A different group
                // does: native UI group identity, rather than groupingKey, wins.
                if let pendingKey, pendingKey != key { flush() }
                pendingKey = key; pending.append((position, message))
            } else {
                rows.append((position, .init(id: message.id, messages: [message])))
            }
        }
        flush()
        return rows.sorted { $0.position < $1.position }.map(\.item)
    }

    private struct GroupKey: Equatable {
        let accountID: Int64, chatID: Int64, peerID: Int64
        let namespace: Int32
        let threadID: Int64?
        let groupID: UInt32
        var id: String { "album:\(accountID):\(chatID):\(peerID):\(namespace):\(threadID.map(String.init) ?? "none"):\(groupID)" }
    }
}

/// Own geometry implementation. Frames retain input order and use the reference
/// four-point gutter; the caller keeps each message's identity and actions.
public enum TelegramAlbumMosaic {
    public static func frames(aspects: [Double], width: Double) -> [CGRect] {
        guard (1...100).contains(aspects.count), width.isFinite, (16...16_384).contains(width) else { return [] }
        let a = aspects.map { $0.isFinite && $0 > 0 ? min(5, max(0.2, $0)) : 1 }
        let gap = 4.0
        func row(_ values: ArraySlice<Double>, y: Double) -> [CGRect] {
            let height = (width - gap * Double(values.count - 1)) / values.reduce(0, +)
            var x = 0.0
            return values.map { aspect in
                let frame = CGRect(x: x, y: y, width: aspect * height, height: height)
                x += frame.width + gap
                return frame
            }
        }
        if a.count == 1 { return row(a[...], y: 0) }
        if a.count == 2 {
            if a.allSatisfy({ $0 > 1.2 }) {
                let h0 = width / a[0], h1 = width / a[1]
                return [CGRect(x: 0, y: 0, width: width, height: h0),
                        CGRect(x: 0, y: h0 + gap, width: width, height: h1)]
            }
            return row(a[...], y: 0)
        }
        if a.count == 3, a[0] < 0.8 {
            let rightWidth = (width - gap * (a[0] + 1)) / (1 + a[0] * (1 / a[1] + 1 / a[2]))
            let leftWidth = width - gap - rightWidth
            let h1 = rightWidth / a[1], h2 = rightWidth / a[2]
            return [CGRect(x: 0, y: 0, width: leftWidth, height: h1 + gap + h2),
                    CGRect(x: leftWidth + gap, y: 0, width: rightWidth, height: h1),
                    CGRect(x: leftWidth + gap, y: h1 + gap, width: rightWidth, height: h2)]
        }
        if a.count == 3 || (a.count == 4 && a[0] > 1.2) {
            let topHeight = min(width / a[0], width * 0.66)
            return [CGRect(x: 0, y: 0, width: width, height: topHeight)] + row(a[1...], y: topHeight + gap)
        }
        if a.count == 4 {
            let first = row(a[0...1], y: 0)
            return first + row(a[2...3], y: first[0].maxY + gap)
        }
        // Choose justified rows around a third of the available width. The
        // bounded dynamic program avoids tiny isolated tiles in longer albums.
        var costs = Array(repeating: Double.infinity, count: a.count + 1)
        var lengths = Array(repeating: 0, count: a.count)
        costs[a.count] = 0
        for start in stride(from: a.count - 1, through: 0, by: -1) {
            for count in 1...min(4, a.count - start) {
                let height = (width - gap * Double(count - 1)) / a[start..<(start + count)].reduce(0, +)
                let distance = height - width / 3
                let penalty = count == 1 ? width * width / 4 : 0
                let cost = distance * distance + penalty + costs[start + count]
                if cost < costs[start] { costs[start] = cost; lengths[start] = count }
            }
        }
        var result: [CGRect] = [], start = 0, y = 0.0
        while start < a.count {
            let count = lengths[start]
            let next = row(a[start..<(start + count)], y: y)
            result.append(contentsOf: next); y = next[0].maxY + gap; start += count
        }
        return result
    }
}
