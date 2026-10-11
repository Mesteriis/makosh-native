import Foundation

public struct TelegramUploadVideoCoverCrop: Equatable, Sendable {
    public enum Corner: Sendable { case topLeft, topRight, bottomLeft, bottomRight }
    public private(set) var rect: CGRect
    private let imageSize: CGSize
    private let aspect: CGFloat
    private var heightPerWidth: CGFloat { imageSize.width / imageSize.height / aspect }

    public init(imageSize: CGSize, videoSize: CGSize) throws {
        guard [imageSize.width, imageSize.height, videoSize.width, videoSize.height].allSatisfy({ $0.isFinite && $0 >= 1 }),
              imageSize.width <= 8192, imageSize.height <= 8192 else { throw TelegramUploadFileError.invalidImage }
        self.imageSize = imageSize
        // The reference's Original candidate has zero difference; a later
        // preset wins only an exact tie. Other videos retain the image's ratio.
        let presets: [CGFloat] = [1, 2.0/3, 3.0/5, 3.0/4, 4.0/5, 5.0/7, 9.0/16, 16.0/9]
        aspect = presets.last(where: { 1 / $0 == videoSize.height / videoSize.width }) ?? imageSize.width / imageSize.height
        let width = min(min(imageSize.width, imageSize.height), imageSize.height * aspect)
        let height = width / aspect
        rect = CGRect(x: (1 - width / imageSize.width) / 2, y: (1 - height / imageSize.height) / 2,
            width: width / imageSize.width, height: height / imageSize.height)
    }
    public mutating func move(by translation: CGSize) {
        guard translation.width.isFinite, translation.height.isFinite else { return }
        rect.origin.x = min(max(0, rect.minX + translation.width), 1 - rect.width)
        rect.origin.y = min(max(0, rect.minY + translation.height), 1 - rect.height)
    }
    public mutating func resize(by translation: CGSize, corner: Corner) {
        guard translation.width.isFinite, translation.height.isFinite else { return }
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let anchor = CGPoint(x: left ? rect.maxX : rect.minX, y: top ? rect.maxY : rect.minY)
        let horizontal = (left ? -1.0 : 1.0) * translation.width
        let vertical = (top ? -1.0 : 1.0) * translation.height / heightPerWidth
        let delta = abs(horizontal) >= abs(vertical) ? horizontal : vertical
        let maximum = min(left ? anchor.x : 1 - anchor.x, (top ? anchor.y : 1 - anchor.y) / heightPerWidth)
        let minimum = min(maximum, max(1, aspect) / imageSize.width)
        let width = min(maximum, max(minimum, rect.width + delta))
        let height = width * heightPerWidth
        rect = CGRect(x: left ? anchor.x - width : anchor.x, y: top ? anchor.y - height : anchor.y,
            width: width, height: height)
    }
}
