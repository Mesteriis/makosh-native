import Foundation
import COpus
import MakoshOpusControl

enum TelegramRecordedVoiceError: Error, Equatable {
    case invalidPCM, invalidRecording, codecUnavailable
}

/// Offline, internal codec for explicit recordings. Never classifies picked files as voice.
enum TelegramRecordedVoiceCodec {
    static let maximumSamples = 28_800_000 //600 seconds,48kHz mono
    static let maximumBytes = 20 * 1024 * 1024
    private static let frameSamples = 960

    static func encode(samples: [Int16]) async throws -> Data {
        try Task.checkCancellation()
        guard !samples.isEmpty, samples.count <= maximumSamples else { throw TelegramRecordedVoiceError.invalidPCM }
        let worker = Task.detached(priority: .utility) { try encodeOwned(samples) }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }

    static func decodeRecording(_ data: Data) async throws -> [Int16] {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumBytes else { throw TelegramRecordedVoiceError.invalidRecording }
        // Normalize nonzero Data slice indices before the bounded parser accesses offsets.
        let worker = Task.detached(priority: .utility) { try decodeOwned(Data(data)) }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        return result
    }

    /// Every native pointer belongs to this synchronous worker and is released before it returns.
    private static func encodeOwned(_ samples: [Int16]) throws -> Data {
        try Task.checkCancellation()
        var status: Int32 = 0
        guard let encoder = opus_encoder_create(48_000, 1, OPUS_APPLICATION_AUDIO, &status) else {
            throw TelegramRecordedVoiceError.codecUnavailable
        }
        defer { opus_encoder_destroy(encoder) }
        var lookahead: Int32 = 0
        guard status == OPUS_OK, makosh_opus_configure_recording(encoder, &lookahead) == OPUS_OK,
              lookahead > 0, lookahead <= frameSamples else { throw TelegramRecordedVoiceError.codecUnavailable }
        let end = samples.count + Int(lookahead)
        let frameCount = (end + frameSamples - 1) / frameSamples
        let serial = UInt32.random(in: 1...UInt32.max)
        var result = TelegramVoiceOgg.page(packet: TelegramVoiceOgg.head(preSkip: UInt16(lookahead)),
            serial: serial, sequence: 0, granule: 0, flags: 2)
        result.append(TelegramVoiceOgg.page(packet: TelegramVoiceOgg.tags, serial: serial, sequence: 1, granule: 0, flags: 0))
        var frame = [Int16](repeating: 0, count: frameSamples)
        var packet = [UInt8](repeating: 0, count: 4_000)
        for index in 0..<frameCount {
            try Task.checkCancellation()
            let start = index * frameSamples
            for offset in 0..<frameSamples { frame[offset] = start + offset < samples.count ? samples[start + offset] : 0 }
            let length = frame.withUnsafeBufferPointer { pcm in
                packet.withUnsafeMutableBufferPointer { output in
                    opus_encode(encoder, pcm.baseAddress!, Int32(frameSamples), output.baseAddress!, Int32(output.count))
                }
            }
            guard length > 0, length <= packet.count else { throw TelegramRecordedVoiceError.codecUnavailable }
            let last = index == frameCount - 1
            result.append(TelegramVoiceOgg.page(packet: Data(packet.prefix(Int(length))), serial: serial,
                sequence: UInt32(index + 2), granule: UInt64(last ? end : (index + 1) * frameSamples), flags: last ? 4 : 0))
            guard result.count <= maximumBytes else { throw TelegramRecordedVoiceError.invalidPCM }
        }
        try Task.checkCancellation()
        return result
    }

    private static func decodeOwned(_ data: Data) throws -> [Int16] {
        let recording = try TelegramVoiceOgg.parseRecording(data)
        var status: Int32 = 0
        guard let decoder = opus_decoder_create(48_000, 1, &status) else { throw TelegramRecordedVoiceError.codecUnavailable }
        defer { opus_decoder_destroy(decoder) }
        guard status == OPUS_OK else { throw TelegramRecordedVoiceError.codecUnavailable }
        var result: [Int16] = []
        result.reserveCapacity(recording.sampleCount)
        var frame = [Int16](repeating: 0, count: frameSamples)
        for (index, packet) in recording.packets.enumerated() {
            try Task.checkCancellation()
            let length = packet.withUnsafeBytes { bytes in
                frame.withUnsafeMutableBufferPointer { output in
                    opus_decode(decoder, bytes.bindMemory(to: UInt8.self).baseAddress,
                        Int32(bytes.count), output.baseAddress!, Int32(frameSamples), 0)
                }
            }
            guard length == frameSamples else { throw TelegramRecordedVoiceError.invalidRecording }
            let start = index * frameSamples
            let lower = max(0, recording.preSkip - start)
            let upper = min(frameSamples, recording.preSkip + recording.sampleCount - start)
            if lower < upper { result.append(contentsOf: frame[lower..<upper]) }
        }
        guard result.count == recording.sampleCount else { throw TelegramRecordedVoiceError.invalidRecording }
        try Task.checkCancellation()
        return result
    }
}
