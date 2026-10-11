import Foundation
import CoreGraphics
import Carbon.HIToolbox

public struct TelegramUploadVideoCoverPainting: Equatable, Sendable {
    public enum Tool: Sendable {
        case draw, arrow, erase
        public func selectingShortcut(keyCode: UInt16) -> Self? {
            switch keyCode {
            case UInt16(kVK_ANSI_A): return self == .arrow ? .draw : .arrow
            case UInt16(kVK_ANSI_E): return .erase
            case UInt16(kVK_ANSI_L): return self == .draw ? .arrow : .draw
            default: return nil
            }
        }
    }
    public struct Stroke: Equatable, Sendable {
        public let tool: Tool
        public let points: [CGPoint]
        public let rgb: UInt32
        public let width: CGFloat
        public let canvasSize: CGSize
        public init(tool: Tool, points: [CGPoint], rgb: UInt32, width: CGFloat, canvasSize: CGSize) throws {
            guard width.isFinite, width > 0, canvasSize.width.isFinite, canvasSize.height.isFinite,
                  canvasSize.width > 0, canvasSize.height > 0,
                  (width * (8192 / canvasSize.width + 8192 / canvasSize.height) / 2).isFinite,
                  points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else {
                throw TelegramUploadFileError.invalidImage
            }
            self.tool = tool; self.points = points; self.rgb = rgb
            self.width = width; self.canvasSize = canvasSize
        }
    }
    public private(set) var strokes: [Stroke] = []
    private var removed: [Stroke] = []
    public var canUndo: Bool { !strokes.isEmpty }
    public var canRedo: Bool { !removed.isEmpty }
    public init() {}
    public mutating func append(_ stroke: Stroke) { strokes.append(stroke); removed.removeAll() }
    public mutating func undo() { if let stroke = strokes.popLast() { removed.append(stroke) } }
    public mutating func redo() { if let stroke = removed.popLast() { strokes.append(stroke) } }
    public func editingCopy() -> Self { var copy = self; copy.removed.removeAll(); return copy }

    /// Points use the original oriented image's normalized top-left coordinates.
    /// A transparency layer confines clear blending to paint, protecting the photo.
    public func draw(in context: CGContext, imageSize: CGSize) {
        guard !strokes.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return }
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: imageSize))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineCap(.round); context.setLineJoin(.round)
        for stroke in strokes {
            let points = stroke.points.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) }
            guard let first = points.first else { continue }
            let width = stroke.width * (imageSize.width / stroke.canvasSize.width + imageSize.height / stroke.canvasSize.height) / 2
            context.beginPath()
            context.setBlendMode(stroke.tool == .erase ? .clear : .normal)
            context.setStrokeColor(CGColor(red: CGFloat((stroke.rgb >> 16) & 255) / 255,
                green: CGFloat((stroke.rgb >> 8) & 255) / 255, blue: CGFloat(stroke.rgb & 255) / 255, alpha: 1))
            context.setLineWidth(stroke.tool == .arrow ? width * 0.7 : width)
            if stroke.tool == .arrow {
                guard points.count > 1, let last = points.last else { continue }
                let dx = last.x - first.x, dy = last.y - first.y
                guard abs(dx) > width * 1.5 || abs(dy) > width * 1.5 else { continue }
                let distance = hypot(dx, dy), head = width * 2.5 / sqrt(2)
                let ux = dx / distance, uy = dy / distance
                context.move(to: first); context.addLine(to: last)
                for sign: CGFloat in [-1, 1] {
                    context.move(to: last)
                    context.addLine(to: CGPoint(x: last.x - head * ux + sign * head * -uy,
                        y: last.y - head * uy + sign * head * ux))
                }
            } else {
                context.move(to: first)
                for point in points.dropFirst() { context.addLine(to: point) }
            }
            context.strokePath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }
}
