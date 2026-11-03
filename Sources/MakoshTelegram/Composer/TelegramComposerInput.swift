import Foundation

public struct TelegramInputSelection: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}

public struct TelegramComposerInput: Codable, Equatable, Sendable {
    public let formattedText: TelegramFormattedText
    public let selection: TelegramInputSelection
    public static let empty = try! TelegramComposerInput(formattedText: TelegramFormattedText(text: ""))
    public init(formattedText: TelegramFormattedText, selection: TelegramInputSelection? = nil) throws {
        guard formattedText.entities.count <= 1024 else { throw TelegramFormattedTextError.invalid }
        let selection = selection ?? TelegramInputSelection(location: formattedText.text.utf16.count, length: 0)
        let count = formattedText.text.utf16.count
        guard selection.location >= 0, selection.length >= 0,
              selection.location <= count, selection.length <= count - selection.location else { throw TelegramFormattedTextError.invalid }
        var boundaries: Set<Int> = [0]
        var offset = 0
        for scalar in formattedText.text.unicodeScalars {
            offset += scalar.value > 0xffff ? 2 : 1; boundaries.insert(offset)
        }
        guard boundaries.contains(selection.location), boundaries.contains(selection.location + selection.length) else { throw TelegramFormattedTextError.invalid }
        self.formattedText = formattedText; self.selection = selection
    }
    private enum ContentKeys: String, CodingKey { case text, entities }
    private enum CodingKeys: String, CodingKey { case formattedText, selection }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let content = try values.nestedContainer(keyedBy: ContentKeys.self, forKey: .formattedText)
        let text = try content.decode(String.self, forKey: .text)
        let entities = try content.decode([TelegramTextEntity].self, forKey: .entities)
        guard text.utf8.count <= 64 * 1024, entities.count <= 1024 else { throw TelegramFormattedTextError.invalid }
        try self.init(formattedText: TelegramFormattedText(text: text, entities: entities), selection: values.decode(TelegramInputSelection.self, forKey: .selection))
    }
}
