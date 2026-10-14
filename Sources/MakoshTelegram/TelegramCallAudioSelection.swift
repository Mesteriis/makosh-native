import Foundation

public struct TelegramCallAudioSelection: Codable, Equatable, Sendable {
    public static let preferenceKey = "Makosh.telegram.callAudio.v1"
    private var version = 1
    public var inputUID: String, outputUID: String
    public init(inputUID: String = "", outputUID: String = "") { self.inputUID = inputUID; self.outputUID = outputUID }
    public enum Failure: Error { case invalidPreferences }
    public var isValid: Bool {
        version == 1 && [inputUID, outputUID].allSatisfy { value in
            value.utf8.count < 128 && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
    }
    public static func decode(_ raw: String) throws -> Self {
        if raw.isEmpty { return .init() }
        guard raw.utf8.count <= 2048 else { throw Failure.invalidPreferences }
        let value = try JSONDecoder().decode(Self.self, from: Data(raw.utf8))
        guard value.isValid else { throw Failure.invalidPreferences }; return value
    }
    public func encoded() throws -> String {
        guard isValid else { throw Failure.invalidPreferences }
        return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
}
