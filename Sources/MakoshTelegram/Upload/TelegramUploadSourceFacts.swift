import Foundation

/// Source selection facts are independent of the generated Telegram payload kind.
public struct TelegramUploadSourceFacts: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Equatable, Sendable { case prepared, original }
    public enum ImageProbe: Codable, Equatable, Sendable {
        case notImage, rejected, decoded(width: Double, height: Double)

        private enum CodingKeys: String, CodingKey { case kind, width, height }

        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(String.self, forKey: .kind) {
            case "notImage":
                try requireSourceFactFields(decoder, expected: ["kind"])
                self = .notImage
            case "rejected":
                try requireSourceFactFields(decoder, expected: ["kind"])
                self = .rejected
            case "decoded":
                try requireSourceFactFields(decoder, expected: ["kind", "width", "height"])
                let width = try values.decode(Double.self, forKey: .width)
                let height = try values.decode(Double.self, forKey: .height)
                guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                        debugDescription: "Invalid source logical image dimensions"))
                }
                self = .decoded(width: width, height: height)
            default:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                    debugDescription: "Unknown source image probe")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .notImage: try values.encode("notImage", forKey: .kind)
            case .rejected: try values.encode("rejected", forKey: .kind)
            case let .decoded(width, height):
                guard width.isFinite, height.isFinite, width > 0, height > 0 else {
                    throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                        debugDescription: "Invalid source logical image dimensions"))
                }
                try values.encode("decoded", forKey: .kind)
                try values.encode(width, forKey: .width)
                try values.encode(height, forKey: .height)
            }
        }
    }
    public enum GroupingProbe: String, Codable, Equatable, Sendable { case ordinary, music, voice, animated }
    public let itemID: UUID
    public let role: Role
    public let name: String
    public let byteCount: Int64
    public let plaintextSHA256: String
    public let selectionMIME: String
    public let image: ImageProbe
    public let grouping: GroupingProbe

    public init(itemID: UUID, role: Role, name: String, byteCount: Int64, plaintextSHA256: String,
                selectionMIME: String, image: ImageProbe, grouping: GroupingProbe) {
        self.itemID = itemID; self.role = role; self.name = name; self.byteCount = byteCount
        self.plaintextSHA256 = plaintextSHA256; self.selectionMIME = selectionMIME
        self.image = image; self.grouping = grouping
    }

    public var isValid: Bool {
        guard itemID != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              name == telegramAttachmentName(name), (0...4_294_967_296).contains(byteCount),
              plaintextSHA256.utf8.count == 64,
              plaintextSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              Self.isValidMIME(selectionMIME) else { return false }
        switch image {
        case .notImage: return !selectionMIME.hasPrefix("image")
        case .rejected: return selectionMIME.hasPrefix("image")
        case let .decoded(width, height):
            return selectionMIME.hasPrefix("image") && width.isFinite && height.isFinite && width > 0 && height > 0
        }
    }

    static func isValidMIME(_ value: String) -> Bool {
        guard value.utf8.count <= 255 else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return parts.allSatisfy { part in
            part.utf8.allSatisfy { byte in
                (97...122).contains(byte) || (48...57).contains(byte) || "!#$&^_.+-".utf8.contains(byte)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case itemID, role, name, byteCount, plaintextSHA256, selectionMIME, image, grouping
    }

    public init(from decoder: any Decoder) throws {
        try requireSourceFactFields(decoder, expected: ["itemID", "role", "name", "byteCount",
            "plaintextSHA256", "selectionMIME", "image", "grouping"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(itemID: try values.decode(UUID.self, forKey: .itemID),
            role: try values.decode(Role.self, forKey: .role),
            name: try values.decode(String.self, forKey: .name),
            byteCount: try values.decode(Int64.self, forKey: .byteCount),
            plaintextSHA256: try values.decode(String.self, forKey: .plaintextSHA256),
            selectionMIME: try values.decode(String.self, forKey: .selectionMIME),
            image: try values.decode(ImageProbe.self, forKey: .image),
            grouping: try values.decode(GroupingProbe.self, forKey: .grouping))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Invalid upload source facts"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard isValid else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath,
                debugDescription: "Invalid upload source facts"))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(itemID, forKey: .itemID)
        try values.encode(role, forKey: .role)
        try values.encode(name, forKey: .name)
        try values.encode(byteCount, forKey: .byteCount)
        try values.encode(plaintextSHA256, forKey: .plaintextSHA256)
        try values.encode(selectionMIME, forKey: .selectionMIME)
        try values.encode(image, forKey: .image)
        try values.encode(grouping, forKey: .grouping)
    }
}

private struct SourceFactField: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requireSourceFactFields(_ decoder: any Decoder, expected: Set<String>) throws {
    let fields = try decoder.container(keyedBy: SourceFactField.self)
    guard Set(fields.allKeys.map(\.stringValue)) == expected else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "Unexpected or missing upload source fact field"))
    }
}
