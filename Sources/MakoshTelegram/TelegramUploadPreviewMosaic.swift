import Foundation

/// Independently authored preview geometry. History keeps its aspect-sensitive layout.
public enum TelegramUploadPreviewMosaic {
    public static func layout(items: [TelegramUploadBatchItem], width: Double, scale: Double) -> (frames: [CGRect], dimensions: CGSize) {
        let raw = rawFrames(items: items, width: width, scale: scale)
        guard !raw.isEmpty else { return ([], .zero) }
        func pixels(_ value: CGFloat) -> CGFloat { floor(value * scale) / scale }
        let dimensions = CGSize(width: pixels(raw.map(\.maxX).max() ?? 0), height: pixels(raw.map(\.maxY).max() ?? 0))
        let frames = raw.map { CGRect(x: pixels($0.minX), y: pixels($0.minY), width: pixels($0.width), height: pixels($0.height)) }
        return (frames, dimensions)
    }

    private static func rawFrames(items: [TelegramUploadBatchItem], width: Double, scale: Double) -> [CGRect] {
        guard (1...10).contains(items.count), width.isFinite, (16...16_384).contains(width),
              scale.isFinite, (1...8).contains(scale),
              items.allSatisfy({ $0.file.mode != .file && $0.file.metadata?.roundVideo == nil }) else { return [] }
        let gap = 4.0
        if items.count == 1 {
            guard let size = TelegramSingleMediaPresentation.uploadSize(items[0].file, availableWidth: min(320, width)) else { return [] }
            return [CGRect(origin: .zero, size: size)]
        }
        if items.count == 2 {
            let side = (width - gap) / 2
            return [CGRect(x: 0, y: 0, width: side, height: side),
                    CGRect(x: side + gap, y: 0, width: side, height: side)]
        }
        if items.count == 3 {
            let top = floor((width - gap) * 0.66), side = (width - gap) / 2
            let bottom = min(width - top - gap, side.rounded())
            return [CGRect(x: 0, y: 0, width: width, height: top),
                    CGRect(x: 0, y: top + gap, width: side, height: bottom),
                    CGRect(x: side + gap, y: top + gap, width: side, height: bottom)]
        }
        if items.count == 4 {
            let left = (width - gap) * 0.6, rightHeight = (width - 2 * gap) / 3
            let rightWidth = min(rightHeight, width - left - gap)
            return ([CGRect(x: 0, y: 0, width: left, height: width)] + (0..<3).map {
                CGRect(x: left + gap, y: Double($0) * (rightHeight + gap), width: rightWidth, height: rightHeight)
            })
        }
        // Enumerate bounded row partitions in reference tie order. Square preview
        // ratios reduce each row to one side length; source dimensions play no role.
        func partitions(_ remaining: Int, rows: Int) -> [[Int]] {
            if rows == 1 { return (1...3).contains(remaining) ? [[remaining]] : [] }
            return (1...3).flatMap { first in
                guard remaining > first else { return [[Int]]() }
                return partitions(remaining - first, rows: rows - 1).map { [first] + $0 }
            }
        }
        func rowHeight(_ count: Int) -> Double { (width - gap * Double(count - 1)) / Double(count) }
        func score(_ counts: [Int]) -> Double {
            let heights = counts.map(rowHeight)
            var distance = abs(heights.reduce(0, +) + gap * Double(counts.count - 1) - width * 4 / 3)
            if zip(counts, counts.dropFirst()).contains(where: { $0 > $1 }) { distance *= 1.5 }
            if heights.min()! < 70 { distance *= 1.5 }
            return distance
        }
        let candidates = [[items.count]] + (2...4).flatMap { partitions(items.count, rows: $0) }
        let selected = candidates.dropFirst().reduce(candidates[0]) { best, next in score(next) < score(best) ? next : best }
        var frames: [CGRect] = [], y = 0.0
        for count in selected {
            let side = rowHeight(count)
            frames += (0..<count).map { CGRect(x: Double($0) * (side + gap), y: y, width: side, height: side) }
            y += side + gap
        }
        return frames
    }
}
