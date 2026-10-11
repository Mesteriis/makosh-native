import Foundation

public struct TelegramMediaRevealState {
    private var revealedAttachment: TelegramAttachment?
    private var revealedContext: UUID?

    public init() {}
    public func isHidden(_ attachment: TelegramAttachment, contextID: UUID) -> Bool {
        attachment.isSpoiler && (revealedContext != contextID || revealedAttachment != attachment)
    }
    public mutating func reveal(_ attachment: TelegramAttachment, contextID: UUID) {
        revealedAttachment = attachment
        revealedContext = contextID
    }
}
