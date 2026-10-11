import Foundation

public struct TelegramUploadWebPMetadata: Codable, Equatable, Sendable {
    public let width: Int32
    public let height: Int32

    public init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        width > 0 && height > 0 && width <= 8192 && height <= 8192 &&
            Int64(width) * Int64(height) <= 40_000_000
    }

    private enum CodingKeys: String, CodingKey { case width, height }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: WebPMetadataKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["width", "height"] else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Unexpected or missing WebP metadata field"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(width: try values.decode(Int32.self, forKey: .width),
            height: try values.decode(Int32.self, forKey: .height))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid WebP dimensions"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                debugDescription: "Invalid WebP dimensions"))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(width, forKey: .width)
        try values.encode(height, forKey: .height)
    }
}

private struct WebPMetadataKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
