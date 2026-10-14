import Foundation

/// Independently parsed public desktop palette fields; unknown fields never become URLs or code.
public struct TelegramCloudPalette: Codable, Equatable, Sendable {
    public let name: String
    public let isDark: Bool
    public let accent: UInt32
    public let background, text, incoming: UInt32?
    public let outgoing: [UInt32]
    var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 256 && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } &&
        accent <= 0xffffff && [background,text,incoming].compactMap { $0 }.allSatisfy { $0 <= 0xffffff } &&
        outgoing.count <= 4 && outgoing.allSatisfy { $0 <= 0xffffff }
    }
    public static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 1_048_576, let text = String(data:data,encoding:.utf8) else { throw TelegramAppearanceError.invalid }
        let lines = text.split(whereSeparator:\.isNewline)
        guard lines.count <= 4096 else { throw TelegramAppearanceError.invalid }
        let known: Set<String> = ["name","isDark","accent","background","text","bubbleBackground_incoming","bubbleBackground_outgoing"]
        var fields: [String:String] = [:]
        for line in lines {
            guard line.utf8.count <= 4096 else { throw TelegramAppearanceError.invalid }
            let trimmed = line.trimmingCharacters(in:.whitespacesAndNewlines)
            if trimmed.hasPrefix("//") || trimmed.isEmpty { continue }
            let pair = trimmed.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in:.whitespacesAndNewlines)
            guard known.contains(key) else { continue }
            guard fields[key] == nil else { throw TelegramAppearanceError.invalid }
            fields[key] = pair[1].trimmingCharacters(in:.whitespacesAndNewlines)
        }
        guard let name = fields["name"], let dark = fields["isDark"], ["0","1"].contains(dark), let accent = fields["accent"] else { throw TelegramAppearanceError.invalid }
        func color(_ value: String) throws -> UInt32 {
            let parts = value.split(separator:":",omittingEmptySubsequences:false)
            guard (1...2).contains(parts.count), parts.count == 1 || Double(parts[1]) == 1 else { throw TelegramAppearanceError.invalid }
            var hex = parts[0].trimmingCharacters(in:.whitespacesAndNewlines)
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.utf8.count == 6, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }), let value = UInt32(hex,radix:16) else { throw TelegramAppearanceError.invalid }; return value
        }
        let outgoing = try fields["bubbleBackground_outgoing"].map { try $0.split(separator:",",omittingEmptySubsequences:false).map { try color(String($0)) } } ?? []
        let palette = Self(name:name,isDark:dark == "1",accent:try color(accent),background:try fields["background"].map(color),text:try fields["text"].map(color),incoming:try fields["bubbleBackground_incoming"].map(color),outgoing:outgoing)
        guard palette.isValid else { throw TelegramAppearanceError.invalid }; return palette
    }
}
