import Foundation

public struct TelegramUploadVideoCoverCrop: Equatable, Sendable {
    public enum Corner: Sendable { case topLeft, topRight, bottomLeft, bottomRight }
    public private(set) var rect: CGRect
    public private(set) var transform = TelegramUploadVideoCoverTransform()
    private var imageSize: CGSize
    private let presetAspect: CGFloat?

    public init(imageSize: CGSize, videoSize: CGSize) throws {
        guard [imageSize.width, imageSize.height, videoSize.width, videoSize.height].allSatisfy({ $0.isFinite && $0 >= 1 }),
              imageSize.width <= 8192, imageSize.height <= 8192 else { throw TelegramUploadFileError.invalidImage }
        self.imageSize = imageSize
        // The reference's Original candidate has zero difference; a later
        // preset wins only an exact tie. Other videos retain the image's ratio.
        let presets: [CGFloat] = [1, 2.0/3, 3.0/5, 3.0/4, 4.0/5, 5.0/7, 9.0/16, 16.0/9]
        presetAspect = presets.last(where: { 1 / $0 == videoSize.height / videoSize.width })
        let aspect = presetAspect ?? imageSize.width / imageSize.height
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
    public mutating func move(from start: CGPoint, to point: CGPoint, canvasSize: CGSize) {
        guard [start.x, start.y, point.x, point.y, canvasSize.width, canvasSize.height].allSatisfy(\.isFinite),
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        move(by: CGSize(width: (ceil(point.x) - ceil(start.x)) / canvasSize.width,
            height: (ceil(point.y) - ceil(start.y)) / canvasSize.height))
    }
    public mutating func resize(to point: CGPoint, corner: Corner, canvasSize: CGSize) {
        guard [point.x, point.y, canvasSize.width, canvasSize.height].allSatisfy(\.isFinite),
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        let x = min(canvasSize.width, max(0, ceil(point.x))) / canvasSize.width
        let edge = corner == .topLeft || corner == .bottomLeft ? rect.minX : rect.maxX
        resize(by: CGSize(width: x - edge, height: 0), corner: corner, canvasSize: canvasSize)
    }
    public mutating func rotate() {
        // Reference crop transport is CCW even while its output mirror is set.
        rect = CGRect(x: rect.minY, y: max(0, 1 - rect.maxX), width: rect.height, height: rect.width)
        imageSize = CGSize(width: imageSize.height, height: imageSize.width)
        transform.rotate()
    }
    public mutating func flipHorizontally() {
        rect.origin.x = max(0, 1 - rect.maxX)
        transform.flipHorizontally()
    }
    public static func fittedImageSize(_ imageSize: CGSize, in bounds: CGSize) -> CGSize {
        guard [imageSize.width, imageSize.height, bounds.width, bounds.height].allSatisfy({ $0.isFinite && $0 > 0 }) else { return .zero }
        var fitted = imageSize
        if fitted.width > bounds.width {
            fitted = CGSize(width: bounds.width, height: ceil(fitted.height * bounds.width / fitted.width))
        }
        if fitted.height > bounds.height {
            fitted = CGSize(width: ceil(fitted.width * bounds.height / fitted.height), height: bounds.height)
        }
        return fitted
    }
    public mutating func fitInitialSelection(canvasSize: CGSize) {
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width >= 1, canvasSize.height >= 1 else { return }
        let ratio = presetAspect.map { 1 / $0 } ?? canvasSize.height / canvasSize.width
        let height = min(canvasSize.height, floor(min(canvasSize.width, canvasSize.height)) * ratio)
        let width = height / ratio
        rect = CGRect(x: (1 - width / canvasSize.width) / 2, y: (1 - height / canvasSize.height) / 2,
            width: width / canvasSize.width, height: height / canvasSize.height)
    }
    public mutating func selectMaximumBounds(canvasSize: CGSize? = nil) {
        let canvas = canvasSize ?? imageSize
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return }
        let ratio = presetAspect.map { canvas.width / canvas.height / $0 } ?? 1
        guard ratio.isFinite, ratio > 0 else { return }
        let width = min(1, 1 / ratio), height = width * ratio
        rect = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
    public mutating func resize(by translation: CGSize, corner: Corner, canvasSize: CGSize? = nil) {
        guard translation.width.isFinite, translation.height.isFinite else { return }
        let canvas = canvasSize ?? imageSize
        guard canvas.width.isFinite, canvas.height.isFinite, canvas.width > 0, canvas.height > 0 else { return }
        let heightPerWidth = presetAspect.map { canvas.width / canvas.height / $0 } ?? 1
        guard heightPerWidth.isFinite, heightPerWidth > 0 else { return }
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let anchor = CGPoint(x: left ? rect.maxX : rect.minX, y: top ? rect.maxY : rect.minY)
        let delta = (left ? -1.0 : 1.0) * translation.width
        let maximum = min(left ? anchor.x : 1 - anchor.x, (top ? anchor.y : 1 - anchor.y) / heightPerWidth)
        let minimum = min(maximum, 40 / canvas.width)
        let width = min(maximum, max(minimum, rect.width + delta))
        let height = width * heightPerWidth
        rect = CGRect(x: left ? anchor.x - width : anchor.x, y: top ? anchor.y - height : anchor.y,
            width: width, height: height)
    }
}
