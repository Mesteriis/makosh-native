import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum TelegramAppearanceError: Error { case invalid, image }
public struct TelegramNightSchedule: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var startMinute, endMinute: Int
    public init(enabled: Bool = false, startMinute: Int = 1320, endMinute: Int = 420) {
        self.enabled = enabled; self.startMinute = startMinute; self.endMinute = endMinute
    }
    var isValid: Bool { (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute) && (!enabled || startMinute != endMinute) }
    public func isNight(at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, isValid, date.timeIntervalSince1970.isFinite else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return false }
        let time = hour * 60 + minute
        return startMinute < endMinute ? time >= startMinute && time < endMinute : time >= startMinute || time < endMinute
    }
}
public enum TelegramLocalWallpaper: Codable, Equatable, Sendable {
    case automatic, solid(UInt32), gradient(UInt32, UInt32), image(String)
    case colors(TelegramWallpaperColors), pattern(TelegramWallpaperPatternSelection)
    var isValid: Bool {
        switch self {
        case .automatic: return true
        case let .solid(color): return color <= 0xffffff
        case let .gradient(a,b): return a <= 0xffffff && b <= 0xffffff
        case let .colors(value): return value.isValid
        case let .pattern(value): return value.isValid
        case let .image(name):
            guard name.hasSuffix(".jpg"), name.utf8.count == 40 else { return false }
            return UUID(uuidString: String(name.dropLast(4))) != nil
        }
    }
}
public struct TelegramAppearancePreferences: Codable, Equatable, Sendable {
    public static let preferenceKey = "Makosh.Telegram.Appearance.v1"
    public var version = 1
    public var fontSize = 14
    public var animationsEnabled = true
    public var replaceEmoticons = false
    public var cloudPalette: TelegramCloudPalette? = nil
    public func effectivePalette(isDark: Bool) -> TelegramCloudPalette? {
        guard let cloudPalette, !night.enabled || cloudPalette.isDark == isDark else { return nil }
        return cloudPalette
    }
    public var night = TelegramNightSchedule()
    public var wallpaper = TelegramLocalWallpaper.automatic
    public init() {}
    private var isValid: Bool { version == 1 && (11...18).contains(fontSize) && night.isValid && wallpaper.isValid && (cloudPalette?.isValid ?? true) }
    public func encoded() throws -> String {
        guard isValid else { throw TelegramAppearanceError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let string = String(data: try encoder.encode(self),encoding:.utf8), string.utf8.count <= 16384 else { throw TelegramAppearanceError.invalid }
        return string
    }
    public static func decode(_ string: String) throws -> Self {
        if string.isEmpty { return .init() }
        guard string.utf8.count <= 16384 else { throw TelegramAppearanceError.invalid }
        let value = try JSONDecoder().decode(Self.self,from:Data(string.utf8))
        guard value.isValid else { throw TelegramAppearanceError.invalid }; return value
    }
}
public enum TelegramWallpaperImage {
    /// Decode a bounded local selection and write a new static JPEG without original metadata.
    public static func prepare(_ input: Data) throws -> Data {
        guard !input.isEmpty, input.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(input as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...16384).contains(width), (1...16384).contains(height), width <= 64_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceThumbnailMaxPixelSize:2560,
                kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw TelegramAppearanceError.image }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw TelegramAppearanceError.image }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length > 0, data.length <= 8 * 1024 * 1024 else { throw TelegramAppearanceError.image }
        return data as Data
    }
}
