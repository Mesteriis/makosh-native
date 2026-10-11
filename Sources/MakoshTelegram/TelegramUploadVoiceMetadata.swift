import Foundation

/// Explicit recorder provenance, never inferred from a picked filename/container.
public struct TelegramUploadVoiceMetadata: Codable, Equatable, Sendable {
    public let sampleCount: Int32
    public let plaintextSHA256: String
    public let waveform: Data?
    public let isOneTime: Bool
    public var duration: Int32 { sampleCount / 48_000 }

    init(sampleCount: Int32, plaintextSHA256: String, waveform: Data? = nil, isOneTime: Bool = false) {
        self.sampleCount = sampleCount; self.plaintextSHA256 = plaintextSHA256; self.waveform = waveform
        self.isOneTime = isOneTime
    }

    public var isValid: Bool {
        (1...28_800_000).contains(sampleCount) && TelegramPendingUploadDraft.isHash(plaintextSHA256) &&
            (waveform.map { $0.count == 63 && $0.last.map { $0 & 0xf0 == 0 } == true } ?? true)
    }

    private enum CodingKeys: String, CodingKey { case sampleCount, plaintextSHA256, waveform, isOneTime }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let hasOneTime = values.contains(.isOneTime)
        try requireAudioMetadataKeys(decoder, expected: hasOneTime
            ? ["sampleCount", "plaintextSHA256", "waveform", "isOneTime"]
            : ["sampleCount", "plaintextSHA256", "waveform"])
        if hasOneTime {
            guard try values.decode(Bool.self, forKey: .isOneTime) else {
                throw DecodingError.dataCorruptedError(forKey: .isOneTime, in: values,
                    debugDescription: "Explicit one-time voice capability must be true")
            }
        }
        self.init(sampleCount: try values.decode(Int32.self, forKey: .sampleCount),
            plaintextSHA256: try values.decode(String.self, forKey: .plaintextSHA256),
            waveform: try values.decodeIfPresent(Data.self, forKey: .waveform), isOneTime: hasOneTime)
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "Invalid recorded voice metadata")) }
    }
    public func encode(to encoder: any Encoder) throws {
        guard isValid else { throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
            debugDescription: "Invalid recorded voice metadata")) }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sampleCount, forKey: .sampleCount)
        try values.encode(plaintextSHA256, forKey: .plaintextSHA256)
        // Null is explicit; a missing field cannot silently lose frozen waveform data.
        try values.encode(waveform, forKey: .waveform)
        // Ordinary schema11 keeps its exact historical three-field representation.
        if isOneTime { try values.encode(true, forKey: .isOneTime) }
    }
}
