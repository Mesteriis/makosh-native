import Foundation
import CoreGraphics

/// Independently parsed public desktop palette fields; unknown fields never become URLs or code.
public struct TelegramCloudPalette: Codable, Equatable, Sendable {
    public let name: String
    public let isDark: Bool
    public let accent: UInt32
    public let background, text, incoming: UInt32?
    public let outgoing: [UInt32]
    public var opacity: [String:Double]? = nil
    public func color(_ field:String,rgb:UInt32) -> CGColor {
        CGColor(red:CGFloat((rgb>>16)&255)/255,green:CGFloat((rgb>>8)&255)/255,blue:CGFloat(rgb&255)/255,alpha:opacity?[field] ?? 1)
    }
    var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 256 && !name.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } &&
        accent <= 0xffffff && [background,text,incoming].compactMap { $0 }.allSatisfy { $0 <= 0xffffff } &&
        outgoing.count <= 4 && outgoing.allSatisfy { $0 <= 0xffffff } &&
        (opacity?.allSatisfy { ["accent","background","text","incoming","outgoing.0","outgoing.1","outgoing.2","outgoing.3"].contains($0.key) && $0.value.isFinite && (0...1).contains($0.value) } ?? true)
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
        var opacity: [String:Double] = [:]
        func color(_ value: String,_ field:String) throws -> UInt32 {
            let parts = value.split(separator:":",omittingEmptySubsequences:false)
            guard (1...2).contains(parts.count) else { throw TelegramAppearanceError.invalid }
            if parts.count == 2 {
                guard let alpha = Double(parts[1].trimmingCharacters(in:.whitespaces)), alpha.isFinite,(0...1).contains(alpha) else { throw TelegramAppearanceError.invalid }
                opacity[field] = alpha
            }
            var hex = parts[0].trimmingCharacters(in:.whitespacesAndNewlines)
            if hex.hasPrefix("#") { hex.removeFirst() }
            guard hex.utf8.count == 6, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }), let value = UInt32(hex,radix:16) else { throw TelegramAppearanceError.invalid }; return value
        }
        let outgoing = try fields["bubbleBackground_outgoing"].map { try $0.split(separator:",",omittingEmptySubsequences:false).enumerated().map { try color(String($0.element),"outgoing.\($0.offset)") } } ?? []
        var palette = Self(name:name,isDark:dark == "1",accent:try color(accent,"accent"),background:try fields["background"].map { try color($0,"background") },text:try fields["text"].map { try color($0,"text") },incoming:try fields["bubbleBackground_incoming"].map { try color($0,"incoming") },outgoing:outgoing)
        palette.opacity = opacity.isEmpty ? nil : opacity
        guard palette.isValid else { throw TelegramAppearanceError.invalid }; return palette
    }
}
