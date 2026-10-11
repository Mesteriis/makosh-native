import Foundation

public struct TelegramUploadAudioMetadata: Codable, Equatable, Sendable {
    public let duration: Int32
    public let title: String
    public let performer: String

    public init(duration: Int32, title: String, performer: String) {
        self.duration = duration
        self.title = title
        self.performer = performer
    }

    public var isValid: Bool {
        (0...604_800).contains(duration) && Self.validTag(title) && Self.validTag(performer)
    }

    private static func validTag(_ value: String) -> Bool {
        value.utf8.count <= 4_096 && !value.utf8.contains(0)
    }

    private enum CodingKeys: String, CodingKey { case duration, title, performer }

    public init(from decoder: Decoder) throws {
        try requireAudioMetadataKeys(decoder, expected: ["duration", "title", "performer"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(duration: try values.decode(Int32.self, forKey: .duration),
            title: try values.decode(String.self, forKey: .title),
            performer: try values.decode(String.self, forKey: .performer))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid audio metadata"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                debugDescription: "Invalid audio metadata"))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(duration, forKey: .duration)
        try values.encode(title, forKey: .title)
        try values.encode(performer, forKey: .performer)
    }
}

public enum TelegramUploadMetadata: Codable, Equatable, Sendable {
    case audio(TelegramUploadAudioMetadata)
    case webP(TelegramUploadWebPMetadata)
    case gif(TelegramUploadGIFMetadata)

    var gif: TelegramUploadGIFMetadata? {
        guard case let .gif(value) = self else { return nil }
        return value
    }

    public var isValid: Bool {
        switch self {
        case let .audio(value): value.isValid
        case let .webP(value): value.isValid
        case let .gif(value): value.isValid
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, payload }

    public init(from decoder: Decoder) throws {
        try requireAudioMetadataKeys(decoder, expected: ["kind", "payload"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .kind) {
        case "audio": self = .audio(try values.decode(TelegramUploadAudioMetadata.self, forKey: .payload))
        case "webp": self = .webP(try values.decode(TelegramUploadWebPMetadata.self, forKey: .payload))
        case "gif": self = .gif(try values.decode(TelegramUploadGIFMetadata.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                debugDescription: "Unknown upload metadata kind")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .audio(value):
            try values.encode("audio", forKey: .kind)
            try values.encode(value, forKey: .payload)
        case let .webP(value):
            try values.encode("webp", forKey: .kind)
            try values.encode(value, forKey: .payload)
        case let .gif(value):
            try values.encode("gif", forKey: .kind)
            try values.encode(value, forKey: .payload)
        }
    }
}

private struct AudioMetadataKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireAudioMetadataKeys(_ decoder: Decoder, expected: Set<String>) throws {
    let values = try decoder.container(keyedBy: AudioMetadataKey.self)
    guard Set(values.allKeys.map(\.stringValue)) == expected else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "Unexpected or missing audio metadata field"))
    }
}
