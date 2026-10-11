import Foundation

public enum TelegramSingleMediaPresentation {
    public static func size(_ attachment: TelegramAttachment, availableWidth: Double, hasCaption: Bool = false) -> CGSize? {
        guard availableWidth.isFinite, (16...16_384).contains(availableWidth),
              attachment.kind == .photo || attachment.playback == .video else { return nil }
        let square = min(320, availableWidth)
        let dimensions = attachment.dimensions
        var width = dimensions.map { Double($0.width) } ?? (attachment.kind == .photo ? square : 300)
        var height = dimensions.map { Double($0.height) } ?? (attachment.kind == .photo ? square : 300)
        func fit(_ limit: Double) {
            let scale = min(1, limit / width, limit / height)
            if scale < 1 { width = min(limit, ceil(width * scale)); height = min(limit, ceil(height * scale)) }
        }
        if attachment.kind == .photo {
            fit(square)
            if width < 100, height < 100 {
                let scale = min(200, availableWidth) / max(width, height)
                width = floor(width * scale); height = floor(height * scale)
            }
            width = max(min(100, square), width)
            height = max(min(46, square), height)
        } else {
            if width < 50, height < 50 { width = square; height = square }
            let normalizedHeight = height + max(0, 300 - width, 300 - height)
            width *= normalizedHeight / height; height = normalizedHeight
            if width > height {
                let scale = min(420, availableWidth) / width
                width = floor(width * scale); height = max(1, floor(height * scale))
            } else { fit(square) }
        }
        if hasCaption { width = max(square, width) }
        return CGSize(width: min(availableWidth, width), height: height)
    }
}
