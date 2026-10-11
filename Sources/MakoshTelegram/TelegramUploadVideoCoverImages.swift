import Foundation
import CoreGraphics

/// Inserted images use captured fitted-canvas points and a source-pixel scale.
/// Immutable bitmaps are retained in value snapshots; source URLs are not used.
public struct TelegramUploadVideoCoverImages: Equatable, Sendable {
    public enum Handle: CaseIterable, Sendable { case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right }
    public struct Item: Identifiable, @unchecked Sendable, Equatable {
        public let id: UUID
        public let image: CGImage
        public let multiplier: CGSize
        public fileprivate(set) var rect: CGRect
        public var pixelRect: CGRect {
            CGRect(x: (rect.minX * multiplier.width).rounded(), y: (rect.minY * multiplier.height).rounded(),
                width: (rect.width * multiplier.width).rounded(), height: (rect.height * multiplier.height).rounded())
        }
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.image === rhs.image && lhs.rect == rhs.rect && lhs.multiplier == rhs.multiplier
        }
    }
    private struct Snapshot: Equatable, Sendable { let items: [Item]; let selection: UUID? }
    public private(set) var items: [Item] = []
    public private(set) var selectedID: UUID?
    private var past: [Snapshot] = []
    private var future: [Snapshot] = []
    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public init() {}
    public mutating func append(_ previews: [TelegramImagePreview], canvasSize: CGSize, imageSize: CGSize? = nil) throws {
        guard !previews.isEmpty else { return }
        var candidate = self
        for preview in previews { try candidate.append(preview, canvasSize: canvasSize, imageSize: imageSize) }
        candidate.past = past; candidate.future = future
        candidate.checkpoint(snapshot)
        self = candidate
    }
    public mutating func append(_ preview: TelegramImagePreview, canvasSize: CGSize, imageSize: CGSize? = nil) throws {
        let sourceSize = imageSize ?? canvasSize
        guard [canvasSize.width, canvasSize.height, sourceSize.width, sourceSize.height].allSatisfy({ $0.isFinite && $0 >= 1 }),
              sourceSize.width <= 8192, sourceSize.height <= 8192,
              preview.image.width <= 8192, preview.image.height <= 8192,
              preview.image.width <= 40_000_000 / preview.image.height, items.count < 16 else { throw TelegramUploadFileError.invalidImage }
        // Include undo-retained assets in the budget; geometry snapshots share
        // their immutable images and do not allocate another bitmap.
        var retained: [UUID: Item] = [:]
        for item in items + past.flatMap(\.items) { retained[item.id] = item }
        let pixels = retained.values.reduce(0) { $0 + $1.image.width * $1.image.height }
        guard pixels + preview.image.width * preview.image.height <= 40_000_000 else { throw TelegramUploadFileError.invalidImage }
        let box = CGSize(width: max(50, min(canvasSize.width / 2, CGFloat(preview.image.width))),
            height: max(50, min(canvasSize.height / 2, CGFloat(preview.image.height))))
        let scale = min(box.width / CGFloat(preview.image.width), box.height / CGFloat(preview.image.height))
        let width = floor(CGFloat(preview.image.width) * scale), height = floor(CGFloat(preview.image.height) * scale)
        let item = Item(id: UUID(), image: preview.image,
            multiplier: CGSize(width: sourceSize.width / canvasSize.width, height: sourceSize.height / canvasSize.height),
            rect: CGRect(x: ((canvasSize.width - width) / 2).rounded(), y: ((canvasSize.height - height) / 2).rounded(), width: width, height: height))
        checkpoint(); items.append(item); selectedID = item.id
    }
    public mutating func select(_ id: UUID?) {
        guard id == nil || items.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }
    public mutating func setRect(_ rect: CGRect, for id: UUID) throws {
        guard [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              rect.size.width >= 0, rect.size.height >= 0, let index = items.firstIndex(where: { $0.id == id }) else { throw TelegramUploadFileError.invalidImage }
        guard items[index].rect != rect else { return }
        checkpoint(); items[index].rect = rect; selectedID = id
    }
    public mutating func move(_ id: UUID, by translation: CGSize, canvasSize: CGSize) throws {
        guard [translation.width, translation.height, canvasSize.width, canvasSize.height].allSatisfy(\.isFinite),
              canvasSize.width > 0, canvasSize.height > 0, let item = items.first(where: { $0.id == id }) else { throw TelegramUploadFileError.invalidImage }
        try setRect(item.rect.offsetBy(dx: translation.width, dy: translation.height), for: id)
    }
    public mutating func resize(_ id: UUID, by translation: CGSize, handle: Handle, preserveAspect: Bool = true) throws {
        guard translation.width.isFinite, translation.height.isFinite,
              let item = items.first(where: { $0.id == id }), item.rect.width > 0, item.rect.height > 0 else { throw TelegramUploadFileError.invalidImage }
        let old = item.rect, dx = translation.width, dy = translation.height, aspect = old.width / old.height
        let horizontal: CGFloat = switch handle { case .topLeft, .bottomLeft, .left: 1; case .topRight, .bottomRight, .right: 0; case .top, .bottom: 0.5 }
        let vertical: CGFloat = switch handle { case .topLeft, .topRight, .top: 1; case .bottomLeft, .bottomRight, .bottom: 0; case .left, .right: 0.5 }
        var width = old.width, height = old.height
        if preserveAspect {
            let change: CGFloat = switch handle {
            case .topLeft: -max(dx, dy)
            case .topRight: max(dx, -dy)
            case .bottomLeft: min(-dx, dy)
            case .bottomRight: min(dx, dy)
            case .top: -dy * aspect
            case .bottom: dy * aspect
            case .left: -dx
            case .right: dx
            }
            width += change; height = width / aspect
        } else {
            switch handle {
            case .topLeft: width -= dx; height -= dy
            case .topRight: width += dx; height -= dy
            case .bottomLeft: width -= dx; height += dy
            case .bottomRight: width += dx; height += dy
            case .top: height -= dy
            case .bottom: height += dy
            // Preserve the reference's inverse orthogonal midpoint rule.
            case .left: width -= dx; height += dx * aspect
            case .right: width += dx; height -= dx * aspect
            }
        }
        width = max(0, width); height = max(0, height)
        try setRect(CGRect(x: old.minX + (old.width - width) * horizontal,
            y: old.minY + (old.height - height) * vertical, width: width, height: height), for: id)
    }
    public mutating func bringSelectedToFront() {
        guard let index = items.firstIndex(where: { $0.id == selectedID }), index != items.count - 1 else { return }
        checkpoint(); items.append(items.remove(at: index))
    }
    public mutating func deleteSelected() {
        guard let index = items.firstIndex(where: { $0.id == selectedID }) else { return }
        checkpoint(); items.remove(at: index); selectedID = items.last?.id
    }
    public mutating func undo() {
        guard let previous = past.popLast() else { return }
        future.append(snapshot); restore(previous)
    }
    public mutating func redo() {
        guard let next = future.popLast() else { return }
        past.append(snapshot); restore(next)
    }
    private var snapshot: Snapshot { Snapshot(items: items, selection: selectedID) }
    private mutating func restore(_ value: Snapshot) { items = value.items; selectedID = value.selection }
    private mutating func checkpoint(_ previous: Snapshot? = nil) {
        past.append(previous ?? snapshot); if past.count > 64 { past.removeFirst() }; future.removeAll()
    }
    /// Context is in transformed source pixels, with a top-left origin.
    func draw(in context: CGContext) {
        for item in items {
            let rect = item.pixelRect
            guard rect.width > 0, rect.height > 0 else { continue }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.draw(item.image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }
}
