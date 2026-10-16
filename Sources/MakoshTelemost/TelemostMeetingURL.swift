import Foundation

public struct TelemostMeetingURL: Codable, Equatable, Sendable {
    public let url: URL
    public let conferenceID: String
    public init(_ text: String) throws {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 8192,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.contains("\\"), let parts = URLComponents(string: value),
              parts.scheme?.lowercased() == "https", parts.host?.lowercased() == "telemost.yandex.ru",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              parts.query == nil, parts.fragment == nil, !parts.percentEncodedPath.contains("%") else { throw TelemostFailure.invalidURL }
        let path = parts.percentEncodedPath
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard path.hasPrefix("/j/") else { throw TelemostFailure.invalidURL }
        let id = String(path.dropFirst(3))
        guard !id.isEmpty, id.utf8.count <= 1024, id.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              let canonical = URL(string: "https://telemost.yandex.ru/j/" + id) else { throw TelemostFailure.invalidURL }
        url = canonical; conferenceID = id
    }
    private enum CodingKeys: String, CodingKey { case url, conferenceID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try values.decode(URL.self, forKey: .url)
        try self.init(raw.absoluteString)
        guard conferenceID.utf8.elementsEqual(try values.decode(String.self, forKey: .conferenceID).utf8) else { throw TelemostFailure.invalidURL }
    }
}
