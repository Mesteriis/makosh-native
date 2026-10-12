# SPDX-License-Identifier: GPL-3.0-or-later
"""Bound pinned forum topic reads before the legacy Postbox pointer decoder."""
import hashlib

SWIFT_TOPIC_GUARD = r"""
// Makosh: validate the pinned topic wire before legacy Postbox reads.
/// CodableEntry uses a legacy pointer reader. Validate the complete current
/// topic wire shape before allowing that reader to inspect retained bytes.
public nonisolated func _makoshDecodeMessageHistoryThreadData(_ entry: CodableEntry) -> MessageHistoryThreadData? {
    guard !entry.data.isEmpty, entry.data.count <= 512 * 1024 else { return nil }
    var wire = MakoshForumTopicWire(bytes: Array(entry.data))
    guard wire.object(0..<wire.bytes.count, depth: 0) else { return nil }
    return entry.get(MessageHistoryThreadData.self)
}

private struct MakoshForumTopicWire {
    let bytes: [UInt8]
    var fields = 0

    mutating func object(_ range: Range<Int>, depth: Int) -> Bool {
        guard depth <= 16 else { return false }
        var offset = range.lowerBound
        var keys = Set<String>()
        var integers: [String: Int32] = [:]
        func take(_ count: Int) -> Range<Int>? {
            guard count >= 0, count <= range.upperBound - offset else { return nil }
            let result = offset..<(offset + count)
            offset += count
            return result
        }
        func length() -> Int? {
            guard let span = take(4) else { return nil }
            var value: UInt32 = 0
            for (shift, index) in span.enumerated() { value |= UInt32(bytes[index]) << (shift * 8) }
            guard value <= UInt32(Int32.max) else { return nil }
            return Int(value)
        }
        func unsigned(_ span: Range<Int>) -> UInt64 {
            var value: UInt64 = 0
            for (shift, index) in span.enumerated() { value |= UInt64(bytes[index]) << (shift * 8) }
            return value
        }
        while offset < range.upperBound {
            fields += 1
            guard fields <= 1024, let header = take(1) else { return false }
            let keyLength = Int(bytes[header.lowerBound])
            guard keyLength > 0, keyLength <= 127, let keySpan = take(keyLength),
                  let key = String(bytes: bytes[keySpan], encoding: .utf8), keys.insert(key).inserted,
                  let tagSpan = take(1) else { return false }
            switch bytes[tagSpan.lowerBound] {
            case 0:
                guard let span = take(4) else { return false }
                let value = Int32(bitPattern: UInt32(unsigned(span)))
                if (key == "m.v" || key == "p.v"), !(0...2).contains(value) { return false }
                if key == "s.v", !(0...4).contains(value) { return false }
                integers[key] = value
            case 1:
                guard let span = take(8) else { return false }
                if key == "iv" {
                    let value = unsigned(span)
                    guard value & 0xf800000000000000 == 0 || value == 0x7fffffff00000000 else { return false }
                }
            case 3: guard take(8) != nil else { return false }
            case 2:
                guard let value = take(1), bytes[value.lowerBound] <= 1 else { return false }
            case 4, 10:
                guard let count = length(), let span = take(count) else { return false }
                if bytes[tagSpan.lowerBound] == 4,
                   String(bytes: bytes[span], encoding: .utf8) == nil { return false }
            case 5:
                guard take(4) != nil, let count = length(), let span = take(count),
                      object(span, depth: depth + 1) else { return false }
            case 11: break
            default:
                // The pinned topic model has no arrays/dictionaries. Unknown
                // profiles fail closed instead of entering unchecked readers.
                return false
            }
        }
        // The native model offsets legacy sound ids using checked Int32 addition.
        let soundID = integers["s.i"] ?? 0
        if integers["s.v"] == 1, soundID > Int32.max - 100 { return false }
        if integers["s.v"] == 2, soundID > Int32.max - 2 { return false }
        return offset == range.upperBound
    }
}
"""

TOPIC_SOURCES = {'submodules/TelegramCore/Sources/ForumChannels.swift': ('5bd10d77c363998a3e15609fd5e65dc90788da8fb6e24faafe689a2445627579',
                                                         '1637bbaacd1e50a1307815134f2c1889fc73f3720d18f4c0d8b252933adfa62e',
                                                         [('transaction.getMessageHistoryThreadInfo(peerId: '
                                                           'peerId, threadId: '
                                                           'threadId)?.data.get(MessageHistoryThreadData.self)',
                                                           'transaction.getMessageHistoryThreadInfo(peerId: '
                                                           'peerId, threadId: threadId).flatMap { '
                                                           '_makoshDecodeMessageHistoryThreadData($0.data) '
                                                           '}',
                                                           3),
                                                          ('transaction.getMessageHistoryThreadInfo(peerId: '
                                                           'id, threadId: '
                                                           'threadId)?.data.get(MessageHistoryThreadData.self)',
                                                           'transaction.getMessageHistoryThreadInfo(peerId: '
                                                           'id, threadId: threadId).flatMap { '
                                                           '_makoshDecodeMessageHistoryThreadData($0.data) '
                                                           '}',
                                                           3)],
                                                         SWIFT_TOPIC_GUARD),
 'submodules/TelegramCore/Sources/SyncCore/SyncCore_StandaloneAccountTransaction.swift': ('cf744dcff07e649f6103b88f807816776e08bc699d6e61801454e8159acd5ee2',
                                                                                          '419e98793e806f91d9df5f2353fbccf1cb2f2631c9cd4b6c68c73a638245e7e5',
                                                                                          [('entry.get(MessageHistoryThreadData.self)',
                                                                                            '_makoshDecodeMessageHistoryThreadData(entry)',
                                                                                            1)],
                                                                                          '')}


def adapt_topic_source(path: str, source: str) -> str:
    original, adapted, replacements, suffix = TOPIC_SOURCES[path]
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == adapted:
        return source
    if digest != original:
        raise ValueError("Unexpected pinned Telegram topic source")
    result = source
    for old, new, count in replacements:
        if result.count(old) != count:
            raise ValueError("Unexpected Telegram topic replacement count")
        result = result.replace(old, new)
    result += suffix
    if hashlib.sha256(result.encode()).hexdigest() != adapted:
        raise ValueError("Unexpected adapted Telegram topic source")
    return result
