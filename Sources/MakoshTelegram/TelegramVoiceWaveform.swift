import Foundation

enum TelegramVoiceWaveform {
    static func make(samples: [Int16]) throws -> Data {
        try Task.checkCancellation()
        guard !samples.isEmpty, samples.count <= TelegramRecordedVoiceCodec.maximumSamples else {
            throw TelegramRecordedVoiceError.invalidPCM
        }
        // The selected recorder previews only complete960-sample packets. Its
        // zero/peak pairs are virtual here; only their bin positions are needed.
        let completeCount = samples.count / 960 * 960
        let windows = completeCount / 100
        var bins = [Int](repeating: 0, count: 100)
        for window in 0..<windows {
            try Task.checkCancellation()
            let start = window * 100
            var magnitude = 0
            for offset in start..<(start + 100) {
                magnitude = max(magnitude, min(32_767, abs(Int(samples[offset]))))
            }
            let bin = (window * 2 + 1) * 100 / (windows * 2)
            bins[bin] = max(bins[bin], magnitude)
        }
        // Preserve the reference's sum of running maxima, including empty bins.
        var running = 0, total = 0
        for magnitude in bins {
            running = max(running, magnitude)
            total += running
        }
        let scale = max(2_500, Int(Double(total) * 1.8 / 100.0))
        var bytes = [UInt8](repeating: 0, count: 63)
        for index in bins.indices {
            let value = UInt16(min(31, bins[index] * 31 / scale))
            let position = index * 5, shift = position % 8, byte = position / 8
            bytes[byte] |= UInt8((value << shift) & 0xff)
            if shift > 3 { bytes[byte + 1] |= UInt8(value >> (8 - shift)) }
        }
        try Task.checkCancellation()
        return Data(bytes)
    }
}
