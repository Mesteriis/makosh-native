import Foundation
import CoreGraphics

public struct TelegramUploadVideoCoverBrush: Equatable, Sendable {
    public static let stops: [(location: Double, rgb: UInt32)] = [
        (0, 0xEA2739), (0.14, 0xDB3AD2), (0.24, 0x3051E3), (0.39, 0x49C5ED),
        (0.49, 0x80C864), (0.62, 0xFCDE65), (0.73, 0xFC964D), (0.85, 0), (1, 0xFFFFFF)
    ]
    public private(set) var colorLocation: Double
    public private(set) var weight: Double
    public init(colorLocation: Double, weight: Double) {
        self.colorLocation = colorLocation.isFinite ? min(1, max(0, colorLocation)) : 1
        self.weight = weight.isFinite ? min(1, max(0, weight)) : 0.22
    }
    public var rgb: UInt32 {
        let right = Self.stops.firstIndex { $0.location > colorLocation } ?? Self.stops.count - 1
        let left = max(0, right - 1), a = Self.stops[left], b = Self.stops[right]
        let fraction = (colorLocation - a.location) / (b.location - a.location)
        return [16, 8, 0].reduce(UInt32(0)) { value, shift in
            let first = Double((a.rgb >> shift) & 255), last = Double((b.rgb >> shift) & 255)
            return value | (UInt32((first + (last - first) * fraction).rounded()) << shift)
        }
    }
    public var lineWidth: CGFloat { CGFloat(floor(4 + 16 * weight) - 2) }
    public func knobDiameter(displayScale: CGFloat, pressed: Bool) -> CGFloat {
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        let raw = CGFloat(4 + 16 * weight) * (pressed ? 2 : 1)
        let value = pressed ? raw : floor(raw)
        let pixels = floor(value * scale)
        let diameter = pixels.isFinite ? pixels / scale : value
        return Int(diameter).isMultiple(of: 2) ? diameter : diameter - 1
    }
    public mutating func updatePicker(point: CGPoint, size: CGSize) {
        guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite, size.width > 48 else { return }
        colorLocation = min(1, max(0, Double((point.x - 24) / (size.width - 48))))
        weight = Double(min(140, max(24, size.height - point.y)) / 140)
    }
}
