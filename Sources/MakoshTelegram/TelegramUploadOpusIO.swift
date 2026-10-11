import Foundation
import Darwin
import COgg
import COpus
import COpusFile

/// Ordinary music only. Recorder intent and the strict Voice profile are separate.
enum TelegramUploadOpusIO {
    private static let maximumBytes: Int64 = 128 * 1024 * 1024
    private static let maximumSamples: Int64 = 604_800 * 48_000

    /// nil leaves non-Opus containers with the existing native audio probe.
    static func inspect(fd: Int32, size: Int64) throws -> TelegramUploadAudioMetadata? {
        let links = try validatePages(fd: fd, size: size)
        guard !links.isEmpty else { return nil }
        try Task.checkCancellation()
        let source = Source(fd: fd, size: size)
        defer { withExtendedLifetime(source) {} }
        let context = Unmanaged.passUnretained(source).toOpaque()
        var callbacks = OpusFileCallbacks(read: { pointer, buffer, requested in
            guard let pointer, let buffer, requested >= 0, !Task.isCancelled else { return -1 }
            let source = Unmanaged<Source>.fromOpaque(pointer).takeUnretainedValue()
            let amount = min(Int64(requested), source.size - source.position)
            guard amount >= 0, amount <= source.budget else { return -1 }
            var actual: Int
            repeat { actual = pread(source.fd, buffer, Int(amount), source.position) }
            while actual < 0 && errno == EINTR && !Task.isCancelled
            guard actual >= 0 else { return -1 }
            source.position += Int64(actual); source.budget -= Int64(actual)
            return Int32(actual)
        }, seek: { pointer, offset, origin in
            guard let pointer, !Task.isCancelled else { return -1 }
            let source = Unmanaged<Source>.fromOpaque(pointer).takeUnretainedValue()
            let base: Int64
            switch origin {
            case SEEK_SET: base = 0
            case SEEK_CUR: base = source.position
            case SEEK_END: base = source.size
            default: return -1
            }
            let (position, overflow) = base.addingReportingOverflow(offset)
            guard !overflow, position >= 0, position <= source.size else { return -1 }
            source.position = position; return 0
        }, tell: { pointer in
            guard let pointer, !Task.isCancelled else { return -1 }
            return Unmanaged<Source>.fromOpaque(pointer).takeUnretainedValue().position
        }, close: nil)
        var error: Int32 = 0
        guard let decoder = op_open_callbacks(context, &callbacks, nil, 0, &error) else {
            try Task.checkCancellation(); throw TelegramUploadFileError.invalidAudio
        }
        defer { op_free(decoder) }
        guard op_seekable(decoder) != 0, op_link_count(decoder) == links.count else { throw TelegramUploadFileError.invalidAudio }
        let total = op_pcm_total(decoder, -1)
        guard total > 0, total <= maximumSamples else { throw TelegramUploadFileError.invalidAudio }
        var offset: Int64 = 0, firstTags = (title: "", performer: "")
        var pcm = [Float](repeating: 0, count: 5_760 * 8)
        for index in links.indices {
            let link = Int32(index)
            try Task.checkCancellation()
            guard let head = op_head(decoder, link), head.pointee.channel_count > 0,
                  head.pointee.channel_count <= 8, let tags = op_tags(decoder, link) else {
                throw TelegramUploadFileError.invalidAudio
            }
            let values = try readTags(tags.pointee)
            if link == 0 { firstTags = values }
            let samples = op_pcm_total(decoder, link)
            guard samples == links[index], samples > 0, samples <= total - offset, op_pcm_seek(decoder, offset) == 0 else {
                throw TelegramUploadFileError.invalidAudio
            }
            // Decode an initial PCM fragment of every link, with bounded buffer and fd reads.
            var decodedLink: Int32 = -1
            let decoded = pcm.withUnsafeMutableBufferPointer {
                op_read_float(decoder, $0.baseAddress, Int32($0.count), &decodedLink)
            }
            guard decoded > 0, decodedLink == link else { throw TelegramUploadFileError.invalidAudio }
            offset += samples
        }
        try Task.checkCancellation()
        guard offset == total else { throw TelegramUploadFileError.invalidAudio }
        return .init(duration: Int32(total / 48_000), title: firstTags.title, performer: firstTags.performer)
    }

    private final class Source {
        let fd: Int32, size: Int64
        var position: Int64 = 0, budget: Int64
        init(fd: Int32, size: Int64) { self.fd = fd; self.size = size; budget = size * 6 + 16 * 1024 * 1024 }
    }

    private static func readTags(_ tags: OpusTags) throws -> (title: String, performer: String) {
        guard tags.comments >= 0, tags.comments <= 4_096,
              tags.comments == 0 || (tags.user_comments != nil && tags.comment_lengths != nil) else {
            throw TelegramUploadFileError.invalidAudio
        }
        var title: String?, performer: String?
        for index in 0..<Int(tags.comments) {
            let size = Int(tags.comment_lengths[index])
            guard size >= 0, size <= 1024 * 1024, let pointer = tags.user_comments[index] else {
                throw TelegramUploadFileError.invalidAudio
            }
            let bytes = UnsafeRawBufferPointer(start: pointer, count: size)
            guard !bytes.contains(0), let value = String(bytes: bytes, encoding: .utf8) else {
                throw TelegramUploadFileError.invalidAudio
            }
            guard let equal = value.firstIndex(of: "=") else { continue }
            let key = value[..<equal].uppercased()
            guard key == "TITLE" || key == "ARTIST" else { continue }
            let text = String(value[value.index(after: equal)...])
            guard text.utf8.count <= 4_096 else { throw TelegramUploadFileError.invalidAudio }
            if key == "TITLE", title == nil { title = text }
            if key == "ARTIST", performer == nil { performer = text }
        }
        return (title ?? "", performer ?? "")
    }

    /// libogg verifies CRC; reject its resynchronization, packet holes, multiplexing,
    /// missing EOS and trailing bytes instead of accepting a repaired stream.
    private static func validatePages(fd: Int32, size: Int64) throws -> [Int64] {
        var magic = [UInt8](repeating: 0, count: 4)
        guard pread(fd, &magic, 4, 0) == 4, magic == Array("OggS".utf8) else { return [] }
        guard size <= maximumBytes else { throw TelegramUploadFileError.invalidAudio }
        var sync = ogg_sync_state(), stream = ogg_stream_state(), page = ogg_page(), packet = ogg_packet()
        guard ogg_sync_init(&sync) == 0 else { throw TelegramUploadFileError.invalidAudio }
        var streamInitialized = false
        defer { if streamInitialized { ogg_stream_clear(&stream) }; ogg_sync_clear(&sync) }
        var readOffset: Int64 = 0, consumed: Int64 = 0, expectedSequence: Int64 = 0
        var serial: Int32?, serials = Set<Int32>(), linkSamples: [Int64] = []
        var packets: Int64 = 0, pendingBytes = 0, preSkip: Int64 = 0
        var previousAudioGranule: Int64?, initialOffset: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = ogg_sync_pageseek(&sync, &page)
            guard count >= 0 else { throw TelegramUploadFileError.invalidAudio }
            if count == 0 {
                if readOffset == size { break }
                let requested = Int(min(65_536, size - readOffset))
                guard let buffer = ogg_sync_buffer(&sync, requested) else { throw TelegramUploadFileError.invalidAudio }
                var actual: Int
                repeat { actual = pread(fd, buffer, requested, readOffset) }
                while actual < 0 && errno == EINTR && !Task.isCancelled
                guard actual > 0, ogg_sync_wrote(&sync, actual) == 0 else { throw TelegramUploadFileError.invalidAudio }
                readOffset += Int64(actual); continue
            }
            consumed += Int64(count)
            guard page.header_len >= 27, page.header[5] & ~UInt8(7) == 0, ogg_page_version(&page) == 0 else {
                throw TelegramUploadFileError.invalidAudio
            }
            let pageSerial = ogg_page_serialno(&page), sequence = ogg_page_pageno(&page)
            if serial == nil {
                guard ogg_page_bos(&page) != 0, ogg_page_continued(&page) == 0, sequence == 0,
                      linkSamples.count < 64, serials.insert(pageSerial).inserted else { throw TelegramUploadFileError.invalidAudio }
                if streamInitialized { ogg_stream_clear(&stream); streamInitialized = false }
                guard ogg_stream_init(&stream, pageSerial) == 0 else { throw TelegramUploadFileError.invalidAudio }
                streamInitialized = true; serial = pageSerial; expectedSequence = 0
                packets = 0; pendingBytes = 0; preSkip = 0; previousAudioGranule = nil; initialOffset = 0
            } else {
                guard pageSerial == serial, ogg_page_bos(&page) == 0,
                      (ogg_page_continued(&page) != 0) == (pendingBytes > 0) else { throw TelegramUploadFileError.invalidAudio }
            }
            guard Int64(sequence) == expectedSequence else { throw TelegramUploadFileError.invalidAudio }
            expectedSequence += 1
            for index in 0..<Int(page.header[26]) {
                let lace = Int(page.header[27 + index]); pendingBytes += lace
                guard pendingBytes <= 1024 * 1024 else { throw TelegramUploadFileError.invalidAudio }
                if lace < 255 { pendingBytes = 0 }
            }
            guard ogg_stream_pagein(&stream, &page) == 0 else { throw TelegramUploadFileError.invalidAudio }
            var pageSamples: Int64 = 0, completedHeader = false
            while true {
                let result = ogg_stream_packetout(&stream, &packet)
                guard result >= 0 else { throw TelegramUploadFileError.invalidAudio }
                if result == 0 { break }
                if packets == 0 {
                    let signature = packet.bytes >= 8 && packet.packet != nil &&
                        UnsafeBufferPointer(start: packet.packet, count: 8).elementsEqual("OpusHead".utf8)
                    if !signature, linkSamples.isEmpty { return [] }
                    guard signature else { throw TelegramUploadFileError.invalidAudio }
                    var head = OpusHead()
                    guard opus_head_parse(&head, packet.packet, packet.bytes) == 0,
                          head.channel_count > 0, head.channel_count <= 8,
                          ogg_page_bos(&page) != 0, ogg_page_packets(&page) == 1,
                          pendingBytes == 0 else { throw TelegramUploadFileError.invalidAudio }
                    preSkip = Int64(head.pre_skip); completedHeader = true
                } else if packets == 1 {
                    completedHeader = true
                } else if packets >= 2 {
                    guard packet.bytes > 0, packet.bytes <= 128 * 1024 else {
                        throw TelegramUploadFileError.invalidAudio
                    }
                    let samples = opus_packet_get_nb_samples(packet.packet, Int32(packet.bytes), 48_000)
                    guard samples > 0 else { throw TelegramUploadFileError.invalidAudio }
                    pageSamples += Int64(samples)
                }
                packets += 1
            }
            let granule = ogg_page_granulepos(&page)
            let end = ogg_page_eos(&page) != 0
            if completedHeader {
                guard pageSamples == 0, pendingBytes == 0, granule == 0, !end else { throw TelegramUploadFileError.invalidAudio }
            } else if pageSamples > 0 {
                guard granule >= 0 else { throw TelegramUploadFileError.invalidAudio }
                if let previous = previousAudioGranule {
                    let (expected, overflow) = previous.addingReportingOverflow(pageSamples)
                    guard !overflow, granule >= previous, end ? granule <= expected : granule == expected else {
                        throw TelegramUploadFileError.invalidAudio
                    }
                } else {
                    // RFC7845§4.4–4.5: cropped initial offset and first-page EOS trimming.
                    guard end || granule >= pageSamples else { throw TelegramUploadFileError.invalidAudio }
                    initialOffset = max(0, granule - pageSamples)
                }
                previousAudioGranule = granule
            } else {
                guard granule == -1, !end else { throw TelegramUploadFileError.invalidAudio }
            }
            if end {
                guard pendingBytes == 0, packets >= 3, granule >= initialOffset,
                      granule - initialOffset > preSkip else { throw TelegramUploadFileError.invalidAudio }
                let samples = granule - initialOffset - preSkip
                guard samples <= maximumSamples else { throw TelegramUploadFileError.invalidAudio }
                linkSamples.append(samples)
                serial = nil
            }
        }
        guard consumed == size, serial == nil, !linkSamples.isEmpty else { throw TelegramUploadFileError.invalidAudio }
        return linkSamples
    }
}
