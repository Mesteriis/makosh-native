import Foundation

/// Explicit authored recorder intent. Picker video metadata never implies a round message.
public struct TelegramUploadRoundVideoMetadata: Codable, Equatable, Sendable {
    public let nativeDuration: Int32
    public let plaintextSHA256: String
    public let isOneTime: Bool
    init(nativeDuration: Int32, plaintextSHA256: String, isOneTime: Bool = false) {
        self.nativeDuration = nativeDuration; self.plaintextSHA256 = plaintextSHA256; self.isOneTime = isOneTime
    }
    public var isValid: Bool { (1...60).contains(nativeDuration) && TelegramPendingUploadDraft.isHash(plaintextSHA256) }

    func isValid(video: TelegramUploadVideoMetadata?, name: String, size: Int64) -> Bool {
        guard isValid, name == "RoundVideo.mp4", size > 0, size <= 128 * 1024 * 1024,
            let video, video.isValid(name: name, size: size), video.width == video.height,
            video.width <= 1024, video.hasAudio, !video.inCollage,
            video.duration >= 0.5, video.duration <= 60,
            Double(nativeDuration) >= video.duration, Double(nativeDuration) - video.duration <= 1 else { return false }
        return true
    }
    private enum CodingKeys: String, CodingKey { case nativeDuration, plaintextSHA256, isOneTime }
    public init(from decoder: any Decoder) throws {
        try requireAudioMetadataKeys(decoder, expected: ["nativeDuration", "plaintextSHA256", "isOneTime"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(nativeDuration: try values.decode(Int32.self, forKey: .nativeDuration), plaintextSHA256: try values.decode(String.self, forKey: .plaintextSHA256),
            isOneTime: try values.decode(Bool.self, forKey: .isOneTime))
        guard isValid else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "Invalid recorded round-video metadata")) }
    }
    public func encode(to encoder: any Encoder) throws {
        guard isValid else { throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
            debugDescription: "Invalid recorded round-video metadata")) }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(nativeDuration, forKey: .nativeDuration)
        try values.encode(plaintextSHA256, forKey: .plaintextSHA256)
        try values.encode(isOneTime, forKey: .isOneTime)
    }
}
