import TelegramCore
import Postbox

struct TelegramMessageEditContent {
    let formatted: TelegramFormattedText
    let captionAboveMedia: Bool
    var invertMediaAttribute: InvertMediaMessageAttribute? {
        captionAboveMedia ? InvertMediaMessageAttribute() : nil
    }
    init?(action: TelegramMessageAction, source: TelegramMessageActionSource) {
        switch action {
        case let .edit(text):
            guard let value = try? TelegramFormattedText(text: text) else { return nil }
            formatted = value
            captionAboveMedia = source.metadata.captionAboveMedia
        case let .editFormatted(value, placement):
            formatted = value
            captionAboveMedia = placement ?? source.metadata.captionAboveMedia
        default: return nil
        }
    }
    func matches(_ message: Message) -> Bool {
        let entities = message.attributes.compactMap { $0 as? TextEntitiesMessageAttribute }.flatMap(\.entities)
        return (try? telegramFormattedText(text: message.text, entities: entities)) == formatted &&
            message.attributes.contains { $0 is InvertMediaMessageAttribute } == captionAboveMedia
    }
}
