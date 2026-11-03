import Foundation

struct TelegramCustomEmojiWebMPacket: Sendable {
    let color: Data
    let alpha: Data?
    let time: Double
    let duration: Double?
    let invisible: Bool
}
struct TelegramCustomEmojiWebM: Sendable {
    let width: Int
    let height: Int
    let hasAlpha: Bool
    let defaultDuration: Double?
    let declaredDuration: Double?
    let packets: [TelegramCustomEmojiWebMPacket]
    init(bytes: Data) throws {
        var parser = TelegramCustomEmojiWebMParser(data: bytes)
        self = try parser.parse()
    }
    fileprivate init(width: Int, height: Int, hasAlpha: Bool, defaultDuration: Double?,
        declaredDuration: Double?, packets: [TelegramCustomEmojiWebMPacket]) {
        self.width = width; self.height = height; self.hasAlpha = hasAlpha
        self.defaultDuration = defaultDuration; self.declaredDuration = declaredDuration; self.packets = packets
    }
}

/// A finite, single-track VP9 sticker profile. Metadata is never executed or
/// followed; payload slices borrow the bounded input rather than expand it.
private struct TelegramCustomEmojiWebMParser {
    struct Element { let id: UInt32; let payload: Range<Int> }
    struct Track { let number: UInt64; let width: Int; let height: Int; let alpha: Bool; let duration: Double? }
    struct Block {
        let track: UInt64; let relative: Int16; let invisible: Bool; let color: Data
        var alpha: Data?; var duration: UInt64?; var cluster: UInt64 = 0
    }
    let data: Data
    var elements = 0
    let globals: Set<UInt32> = [0xec, 0xbf]

    mutating func parse() throws -> TelegramCustomEmojiWebM {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw TelegramCustomEmojiError.invalid }
        var cursor = 0
        let header = try element(at: &cursor, end: data.count)
        guard header.id == 0x1a45dfa3 else { throw TelegramCustomEmojiError.invalid }
        try validateHeader(header.payload)
        var segment: Element?
        while cursor < data.count {
            let next = try element(at: &cursor, end: data.count, unknownSegment: true)
            if next.id == 0x18538067 {
                guard segment == nil else { throw TelegramCustomEmojiError.invalid }; segment = next
            } else if !globals.contains(next.id) { throw TelegramCustomEmojiError.invalid }
        }
        guard let segment else { throw TelegramCustomEmojiError.invalid }
        var info: Element?, tracks: Element?, blocks: [Block] = []
        cursor = segment.payload.lowerBound
        while cursor < segment.payload.upperBound {
            let next = try element(at: &cursor, end: segment.payload.upperBound)
            switch next.id {
            case 0x1549a966:
                guard info == nil else { throw TelegramCustomEmojiError.invalid }; info = next
            case 0x1654ae6b:
                guard tracks == nil else { throw TelegramCustomEmojiError.invalid }; tracks = next
            case 0x1f43b675: blocks += try cluster(next.payload)
            case 0x1a45dfa3, 0x18538067: throw TelegramCustomEmojiError.invalid
            default: break // finite seek/cue/tag metadata has no decoding authority
            }
            guard blocks.count <= 3240 else { throw TelegramCustomEmojiError.invalid }
        }
        guard let info, let tracks, !blocks.isEmpty else { throw TelegramCustomEmojiError.invalid }
        let (scale, declaredDuration) = try information(info.payload)
        let track = try trackList(tracks.payload)
        var packets: [TelegramCustomEmojiWebMPacket] = [], previous = -Double.infinity
        for block in blocks {
            try Task.checkCancellation()
            guard block.track == track.number, track.alpha == (block.alpha != nil),
                  block.cluster <= UInt64(Int64.max) else { throw TelegramCustomEmojiError.invalid }
            let (ticks, overflow) = Int64(block.cluster).addingReportingOverflow(Int64(block.relative))
            let time = Double(ticks) * scale
            let duration = block.duration.map { Double($0) * scale }
            guard !overflow, ticks >= 0, time.isFinite, time >= previous, time <= 9,
                  duration == nil || (duration!.isFinite && duration! > 0 && duration! <= 9) else {
                throw TelegramCustomEmojiError.invalid
            }
            previous = time
            packets.append(.init(color: block.color, alpha: block.alpha, time: time,
                duration: duration, invisible: block.invisible))
        }
        return .init(width: track.width, height: track.height, hasAlpha: track.alpha,
            defaultDuration: track.duration, declaredDuration: declaredDuration, packets: packets)
    }

    mutating func validateHeader(_ range: Range<Int>) throws {
        var cursor = range.lowerBound, seen: Set<UInt32> = [], type: String?
        while cursor < range.upperBound {
            let next = try element(at: &cursor, end: range.upperBound)
            if globals.contains(next.id) { continue }
            guard seen.insert(next.id).inserted else { throw TelegramCustomEmojiError.invalid }
            switch next.id {
            case 0x4282: type = String(data: slice(next.payload), encoding: .utf8)
            case 0x4286, 0x42f7: guard try uint(next.payload) == 1 else { throw TelegramCustomEmojiError.invalid }
            case 0x42f2: guard (1...4).contains(try uint(next.payload)) else { throw TelegramCustomEmojiError.invalid }
            case 0x42f3: guard (1...8).contains(try uint(next.payload)) else { throw TelegramCustomEmojiError.invalid }
            case 0x4285: guard (1...4).contains(try uint(next.payload)) else { throw TelegramCustomEmojiError.invalid }
            default: break
            }
        }
        guard type == "webm" else { throw TelegramCustomEmojiError.invalid }
    }
    mutating func information(_ range: Range<Int>) throws -> (Double, Double?) {
        var cursor = range.lowerBound, seen: Set<UInt32> = [], nanoseconds: UInt64 = 1_000_000, duration: Double?
        while cursor < range.upperBound {
            let next = try element(at: &cursor, end: range.upperBound)
            if globals.contains(next.id) { continue }
            guard seen.insert(next.id).inserted else { throw TelegramCustomEmojiError.invalid }
            if next.id == 0x2ad7b1 { nanoseconds = try uint(next.payload) }
            if next.id == 0x4489 { duration = try floating(next.payload) }
        }
        let scale = Double(nanoseconds) / 1_000_000_000
        let seconds = duration.map { $0 * scale }
        guard nanoseconds > 0, scale.isFinite, seconds == nil ||
                (seconds!.isFinite && seconds! > 0 && seconds! <= 9) else { throw TelegramCustomEmojiError.invalid }
        return (scale, seconds)
    }
    mutating func trackList(_ range: Range<Int>) throws -> Track {
        var cursor = range.lowerBound, result: Track?
        while cursor < range.upperBound {
            let next = try element(at: &cursor, end: range.upperBound)
            if next.id == 0xae {
                guard result == nil else { throw TelegramCustomEmojiError.invalid }
                result = try track(next.payload)
            } else if !globals.contains(next.id) { throw TelegramCustomEmojiError.invalid }
        }
        guard let result else { throw TelegramCustomEmojiError.invalid }; return result
    }
    mutating func track(_ range: Range<Int>) throws -> Track {
        var cursor = range.lowerBound, seen: Set<UInt32> = [], number: UInt64?, kind: UInt64?, codec: String?
        var video: (Int, Int, Bool)?, duration: Double?
        while cursor < range.upperBound {
            let next = try element(at: &cursor, end: range.upperBound)
            if globals.contains(next.id) { continue }
            guard seen.insert(next.id).inserted else { throw TelegramCustomEmojiError.invalid }
            switch next.id {
            case 0xd7: number = try uint(next.payload)
            case 0x83: kind = try uint(next.payload)
            case 0x86: codec = String(data: slice(next.payload), encoding: .utf8)
            case 0xe0: video = try videoFormat(next.payload)
            case 0x23e383: duration = Double(try uint(next.payload)) / 1_000_000_000
            case 0x6d80, 0x41e4: throw TelegramCustomEmojiError.invalid // content transforms/encryption or unsupported block mappings
            case 0xb9: guard try uint(next.payload) == 1 else { throw TelegramCustomEmojiError.invalid }
            case 0x23314f: guard try floating(next.payload) == 1 else { throw TelegramCustomEmojiError.invalid }
            case 0x537f, 0x56aa: guard try uint(next.payload) == 0 else { throw TelegramCustomEmojiError.invalid }
            default: break
            }
        }
        guard let number, number > 0, kind == 1, codec == "V_VP9", let video,
              duration == nil || (duration!.isFinite && duration! > 0 && duration! <= 9) else {
            throw TelegramCustomEmojiError.invalid
        }
        return .init(number: number, width: video.0, height: video.1, alpha: video.2, duration: duration)
    }
    mutating func videoFormat(_ range: Range<Int>) throws -> (Int, Int, Bool) {
        var cursor = range.lowerBound, seen: Set<UInt32> = [], fields: [UInt32: UInt64] = [:]
        while cursor < range.upperBound {
            let next = try element(at: &cursor, end: range.upperBound)
            if globals.contains(next.id) { continue }
            guard seen.insert(next.id).inserted else { throw TelegramCustomEmojiError.invalid }
            switch next.id {
            case 0x55b0: try colour(next.payload)
            case 0x53b8:
                guard try uint(next.payload) == 0 else { throw TelegramCustomEmojiError.invalid }
            case 0x7670: throw TelegramCustomEmojiError.invalid // projection transforms are outside the flat sticker profile
            case 0xb0, 0xba, 0x53c0, 0x54b0, 0x54ba, 0x54b2, 0x54aa, 0x54bb, 0x54cc, 0x54dd:
                fields[next.id] = try uint(next.payload)
            default: break
            }
        }
        guard let width = fields[0xb0], let height = fields[0xba], (1...512).contains(width),
              (1...512).contains(height), (fields[0x53c0] ?? 0) <= 1,
              fields[0x54b0] == nil || fields[0x54b0] == width, fields[0x54ba] == nil || fields[0x54ba] == height,
              [0x54b2, 0x54aa, 0x54bb, 0x54cc, 0x54dd].allSatisfy({ (fields[UInt32($0)] ?? 0) == 0 }) else {
            throw TelegramCustomEmojiError.invalid
        }
        return (Int(width), Int(height), fields[0x53c0] == 1)
    }

    // SDR 8-bit 4:2:0 only. Unspecified matrix/transfer/primaries preserve
    // the bitstream values; unsupported external color transforms fall back.
    mutating func colour(_ range: Range<Int>) throws {
        var cursor = range.lowerBound, seen: Set<UInt32> = []
        while cursor < range.upperBound {
            let field = try element(at: &cursor, end: range.upperBound)
            if globals.contains(field.id) { continue }
            guard seen.insert(field.id).inserted else { throw TelegramCustomEmojiError.invalid }
            let value = try uint(field.payload)
            switch field.id {
            case 0x55b1, 0x55ba, 0x55bb: guard value == 2 else { throw TelegramCustomEmojiError.invalid }
            case 0x55b2: guard value == 0 || value == 8 else { throw TelegramCustomEmojiError.invalid }
            case 0x55b3, 0x55b4: guard value == 1 else { throw TelegramCustomEmojiError.invalid }
            case 0x55b5, 0x55b6, 0x55b7, 0x55b8: guard value == 0 else { throw TelegramCustomEmojiError.invalid }
            case 0x55b9: guard value <= 1 else { throw TelegramCustomEmojiError.invalid }
            default: throw TelegramCustomEmojiError.invalid
            }
        }
    }

    mutating func cluster(_ range: Range<Int>) throws -> [Block] {
        var cursor = range.lowerBound, timestamp: UInt64?, blocks: [Block] = []
        while cursor < range.upperBound {
            let next = try element(at: &cursor, end: range.upperBound)
            switch next.id {
            case 0xe7:
                guard timestamp == nil else { throw TelegramCustomEmojiError.invalid }; timestamp = try uint(next.payload)
            case 0xa3: blocks.append(try block(next.payload, simple: true))
            case 0xa0: blocks.append(try group(next.payload))
            case 0xaf: throw TelegramCustomEmojiError.invalid // encrypted block
            default: break
            }
            guard blocks.count <= 3240 else { throw TelegramCustomEmojiError.invalid }
        }
        guard let timestamp else { throw TelegramCustomEmojiError.invalid }
        return blocks.map { var value = $0; value.cluster = timestamp; return value }
    }
    mutating func group(_ range: Range<Int>) throws -> Block {
        var cursor = range.lowerBound, result: Block?, mask: Data?, duration: UInt64?, seen: Set<UInt32> = []
        while cursor < range.upperBound {
            let next = try element(at: &cursor, end: range.upperBound)
            if globals.contains(next.id) || next.id == 0xfb { continue } // multiple reference timestamps are permitted
            guard seen.insert(next.id).inserted else { throw TelegramCustomEmojiError.invalid }
            switch next.id {
            case 0xa1: result = try block(next.payload, simple: false)
            case 0x75a1: mask = try additions(next.payload)
            case 0x9b: duration = try uint(next.payload)
            case 0xa4, 0xa2, 0x75a2: throw TelegramCustomEmojiError.invalid // codec state, virtual blocks, padding
            default: break
            }
        }
        guard var result else { throw TelegramCustomEmojiError.invalid }
        result.alpha = mask; result.duration = duration; return result
    }
    mutating func additions(_ range: Range<Int>) throws -> Data {
        var cursor = range.lowerBound, mask: Data?
        while cursor < range.upperBound {
            let next = try element(at: &cursor, end: range.upperBound)
            if globals.contains(next.id) { continue }
            guard next.id == 0xa6, mask == nil else { throw TelegramCustomEmojiError.invalid }
            var child = next.payload.lowerBound, id: UInt64 = 1, value: Data?, seen: Set<UInt32> = []
            while child < next.payload.upperBound {
                let field = try element(at: &child, end: next.payload.upperBound)
                guard seen.insert(field.id).inserted else { throw TelegramCustomEmojiError.invalid }
                if field.id == 0xee { id = try uint(field.payload) }
                else if field.id == 0xa5 { value = slice(field.payload) }
                else if !globals.contains(field.id) { throw TelegramCustomEmojiError.invalid }
            }
            guard id == 1, let value, !value.isEmpty else { throw TelegramCustomEmojiError.invalid }; mask = value
        }
        guard let mask else { throw TelegramCustomEmojiError.invalid }; return mask
    }
    func block(_ range: Range<Int>, simple: Bool) throws -> Block {
        var cursor = range.lowerBound
        let (track, _, _) = try vint(at: &cursor, end: range.upperBound, identifier: false)
        guard track > 0, range.upperBound - cursor >= 4 else { throw TelegramCustomEmojiError.invalid }
        let relative = Int16(bitPattern: UInt16(byte(cursor)) << 8 | UInt16(byte(cursor + 1)))
        let flags = byte(cursor + 2); cursor += 3
        guard flags & 0x06 == 0, flags & (simple ? 0x70 : 0xf1) == 0 else { throw TelegramCustomEmojiError.invalid }
        return .init(track: track, relative: relative, invisible: flags & 0x08 != 0,
            color: slice(cursor..<range.upperBound), alpha: nil, duration: nil)
    }

    mutating func element(at cursor: inout Int, end: Int, unknownSegment: Bool = false) throws -> Element {
        try Task.checkCancellation()
        elements += 1
        guard elements <= 20_000 else { throw TelegramCustomEmojiError.invalid }
        let (identifier, _, _) = try vint(at: &cursor, end: end, identifier: true)
        let (size, _, unknown) = try vint(at: &cursor, end: end, identifier: false)
        guard identifier <= UInt32.max, (!unknown || (unknownSegment && identifier == 0x18538067)),
              unknown || size <= UInt64(end - cursor) else { throw TelegramCustomEmojiError.invalid }
        let range = cursor..<(unknown ? end : cursor + Int(size)); cursor = range.upperBound
        return .init(id: UInt32(identifier), payload: range)
    }
    func vint(at cursor: inout Int, end: Int, identifier: Bool) throws -> (UInt64, Int, Bool) {
        guard cursor < end, byte(cursor) != 0 else { throw TelegramCustomEmojiError.invalid }
        let first = byte(cursor)
        guard let count = (1...8).first(where: { first & (1 << (8 - $0)) != 0 }),
              count <= end - cursor, !identifier || count <= 4 else { throw TelegramCustomEmojiError.invalid }
        var value: UInt64 = 0
        for index in cursor..<cursor + count { value = value << 8 | UInt64(byte(index)) }
        cursor += count
        if identifier { return (value, count, false) }
        let mask = (UInt64(1) << (7 * count)) - 1
        value &= mask
        return (value, count, value == mask)
    }
    func uint(_ range: Range<Int>) throws -> UInt64 {
        guard range.count <= 8 else { throw TelegramCustomEmojiError.invalid }
        return range.reduce(UInt64(0)) { $0 << 8 | UInt64(byte($1)) }
    }
    func floating(_ range: Range<Int>) throws -> Double {
        let bits = try uint(range)
        let result: Double
        if range.count == 4 { result = Double(Float(bitPattern: UInt32(bits))) }
        else if range.count == 8 { result = Double(bitPattern: bits) }
        else { throw TelegramCustomEmojiError.invalid }
        guard result.isFinite else { throw TelegramCustomEmojiError.invalid }; return result
    }
    func byte(_ index: Int) -> UInt8 { data[data.startIndex + index] }
    func slice(_ range: Range<Int>) -> Data { data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)] }
}
