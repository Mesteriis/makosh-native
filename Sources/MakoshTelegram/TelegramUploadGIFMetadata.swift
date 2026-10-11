import Foundation

/// Facts of the original GIF, distinct from measured MP4 duration and wire attributes.
public struct TelegramUploadGIFMetadata: Codable, Equatable, Sendable {
    public let width: Int32
    public let height: Int32
    public let frameDurations: [Float]
    public let sourceSHA256: String

    public init(width: Int32, height: Int32, frameDurations: [Float], sourceSHA256: String) {
        self.width = width; self.height = height
        self.frameDurations = frameDurations; self.sourceSHA256 = sourceSHA256
    }

    public var isValid: Bool {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              Int64(width) * Int64(height) <= 16_000_000,
              (1...256).contains(frameDurations.count),
              Int64(width) * Int64(height) * Int64(frameDurations.count) <= 256_000_000,
              frameDurations.allSatisfy({ $0.isFinite && $0 >= Float(0.011) }),
              frameDurations.reduce(0.0, { $0 + Double($1) }) <= 600,
              TelegramPendingUploadDraft.isHash(sourceSHA256) else { return false }
        return true
    }

    var info: TelegramUploadGIFInfo { .init(width: width, height: height, frameDurations: frameDurations) }

    private enum CodingKeys: String, CodingKey { case width, height, frameDurations, sourceSHA256 }
    private struct FieldKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: FieldKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["width", "height", "frameDurations", "sourceSHA256"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unexpected or missing GIF metadata field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try values.decode(Int32.self, forKey: .width),
            height: try values.decode(Int32.self, forKey: .height),
            frameDurations: try values.decode([Float].self, forKey: .frameDurations),
            sourceSHA256: try values.decode(String.self, forKey: .sourceSHA256))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid GIF source facts"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                debugDescription: "Invalid GIF source facts"))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(width, forKey: .width); try values.encode(height, forKey: .height)
        try values.encode(frameDurations, forKey: .frameDurations)
        try values.encode(sourceSHA256, forKey: .sourceSHA256)
    }
}
