import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import zlib

public struct TelegramWallpaperColors: Codable, Equatable, Sendable {
    public var colors: [UInt32]
    public var rotation: Int
    public var phase: Int
    public init(colors:[UInt32],rotation:Int = 0,phase:Int = 0) { self.colors = colors; self.rotation = rotation; self.phase = phase }
    public static func parseHex(_ input:String) -> UInt32? {
        guard input.utf8.count <= 32 else { return nil }
        var text = input.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.utf8.count == 6,text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return UInt32(text,radix:16)
    }
    var isValid: Bool {
        (1...4).contains(colors.count) && colors.allSatisfy { $0 <= 0xffffff } &&
        (0...315).contains(rotation) && rotation % 45 == 0 && (0...3).contains(phase) &&
        (colors.count == 2 || rotation == 0) && (colors.count > 2 || phase == 0)
    }
}
public struct TelegramWallpaperPatternSelection: Codable, Equatable, Sendable {
    public let name: String
    public var colors: TelegramWallpaperColors
    public var intensity: Int
    public init(name:String,colors:TelegramWallpaperColors,intensity:Int) { self.name = name; self.colors = colors; self.intensity = intensity }
    var isValid: Bool { TelegramWallpaperPattern.validName(name) && colors.isValid && (-100...100).contains(intensity) }
}
public struct TelegramPreparedPattern: Equatable, Sendable {
    public let data: Data
    public let colors: TelegramWallpaperColors
    public let intensity: Int
    var isValid: Bool { colors.isValid && (-100...100).contains(intensity) && TelegramWallpaperPattern.normalizedImage(data) != nil }
}

/// Converts a bounded vector/raster mask to metadata-free static PNG. Untrusted
/// XML is allowlisted before AppKit sees it; no URLs, entities, fonts or scripts.
public enum TelegramWallpaperPattern {
    static func validName(_ name:String) -> Bool {
        name.utf8.count == 40 && name.hasSuffix(".png") && UUID(uuidString:String(name.dropLast(4))) != nil
    }
    static func normalizedImage(_ data:Data) -> CGImage? {
        guard !data.isEmpty, data.count <= 8_388_608,
              let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.png.identifier, CGImageSourceGetCount(source) == 1,
              let p = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
              (1...1024).contains(w), (1...1024).contains(h) else { return nil }
        return CGImageSourceCreateImageAtIndex(source,0,nil)
    }
    public static func prepare(_ input:Data) throws -> Data {
        guard !input.isEmpty, input.count <= 2_097_152 else { throw TelegramAppearanceError.image }
        let data = input.starts(with:[0x1f,0x8b]) ? try unzip(input) : input
        try Task.checkCancellation()
        let image: CGImage
        if let text = String(data:data,encoding:.utf8), text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("<") {
            let checked = try PatternXML.validate(data)
            guard let native = NSImage(data:data), native.isValid,
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:checked.0,pixelsHigh:checked.1,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:checked.0*4,bitsPerPixel:32),
                  let graphics = NSGraphicsContext(bitmapImageRep:bitmap) else { throw TelegramAppearanceError.image }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            native.draw(in:NSRect(x:0,y:0,width:checked.0,height:checked.1),from:.zero,operation:.copy,fraction:1)
            NSGraphicsContext.restoreGraphicsState()
            guard let decoded = bitmap.cgImage else { throw TelegramAppearanceError.image }; image = decoded
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  [UTType.png.identifier,UTType.webP.identifier].contains(CGImageSourceGetType(source) as String? ?? ""),
                  CGImageSourceGetCount(source) == 1,
                  let p = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int,let h = p[kCGImagePropertyPixelHeight] as? Int,
                  (1...16384).contains(w),(1...16384).contains(h),w <= 16_000_000/h,
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:1024,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { throw TelegramAppearanceError.image }
            image = decoded
        }
        try Task.checkCancellation()
        let result = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(result,UTType.png.identifier as CFString,1,nil) else { throw TelegramAppearanceError.image }
        CGImageDestinationAddImage(dest,image,nil)
        guard CGImageDestinationFinalize(dest), result.length <= 8_388_608 else { throw TelegramAppearanceError.image }
        return result as Data
    }
    private static func unzip(_ data:Data) throws -> Data {
        let stream = UnsafeMutablePointer<z_stream>.allocate(capacity:1); stream.initialize(to:z_stream())
        defer { stream.deinitialize(count:1); stream.deallocate() }
        guard inflateInit2_(stream,MAX_WBITS+16,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TelegramAppearanceError.image }
        defer { inflateEnd(stream) }
        return try data.withUnsafeBytes { bytes in
            stream.pointee.next_in = UnsafeMutablePointer(mutating:bytes.bindMemory(to:Bytef.self).baseAddress); stream.pointee.avail_in = uInt(bytes.count)
            defer { stream.pointee.next_in = nil }
            var result = Data()
            while true {
                try Task.checkCancellation()
                var chunk = Data(count:65_536); let before = stream.pointee.avail_in
                let (status,count) = chunk.withUnsafeMutableBytes { output -> (Int32,Int) in
                    stream.pointee.next_out = output.bindMemory(to:Bytef.self).baseAddress; stream.pointee.avail_out = uInt(output.count)
                    defer { stream.pointee.next_out = nil }
                    let status = inflate(stream,Z_NO_FLUSH); return (status,output.count-Int(stream.pointee.avail_out))
                }
                guard status == Z_OK || status == Z_STREAM_END, count <= 2_097_152-result.count,
                      status == Z_STREAM_END || count > 0 || stream.pointee.avail_in < before else { throw TelegramAppearanceError.image }
                chunk.count = count; result.append(chunk)
                if status == Z_STREAM_END { guard stream.pointee.avail_in == 0 else { throw TelegramAppearanceError.image }; return result }
            }
        }
    }
}

private final class PatternXML: NSObject, XMLParserDelegate {
    private var depth = 0, nodes = 0, tokens = 0, invalid = false
    private var dimensions = (512,1024)
    private static let elements: Set<String> = ["svg","g","path","rect","circle","ellipse","line","polygon","polyline"]
    private static let attributes: Set<String> = ["xmlns","width","height","viewBox","fill","fill-opacity","opacity","stroke","stroke-opacity","stroke-width","stroke-linecap","stroke-linejoin","stroke-miterlimit","fill-rule","clip-rule","transform","d","points","x","y","x1","y1","x2","y2","rx","ry","cx","cy","r","version","preserveAspectRatio"]
    static func validate(_ data:Data) throws -> (Int,Int) {
        guard let text = String(data:data,encoding:.utf8), !text.contains("<!"), !text.contains("&"),
              !text.lowercased().contains("url(") else { throw TelegramAppearanceError.image }
        let delegate = PatternXML(), parser = XMLParser(data:data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.depth == 0, delegate.nodes > 0 else { throw TelegramAppearanceError.image }
        return delegate.dimensions
    }
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        depth += 1; nodes += 1
        guard depth <= 32,nodes <= 4096,Self.elements.contains(elementName),depth != 1 || elementName == "svg",
              attributes.count <= 32 else { reject(parser); return }
        for (key,value) in attributes {
            guard Self.attributes.contains(key),value.utf8.count <= 262_144 else { reject(parser); return }
            if key == "xmlns" { guard depth == 1,value == "http://www.w3.org/2000/svg" else { reject(parser); return }; continue }
            if ["fill","stroke"].contains(key) {
                guard value == "none" || value == "black" || value == "white" || (value.hasPrefix("#") && [4,7,9].contains(value.count) && value.dropFirst().allSatisfy(\.isHexDigit)) else { reject(parser); return }; continue
            }
            if ["fill-rule","clip-rule"].contains(key) { guard ["nonzero","evenodd"].contains(value) else { reject(parser); return }; continue }
            if key == "stroke-linecap" { guard ["butt","round","square"].contains(value) else { reject(parser); return }; continue }
            if key == "stroke-linejoin" { guard ["miter","round","bevel"].contains(value) else { reject(parser); return }; continue }
            if key == "preserveAspectRatio" { guard ["none","xMidYMid meet","xMidYMid slice"].contains(value) else { reject(parser); return }; continue }
            var numeric = value
            if key == "transform" {
                for operation in ["translate","scale","rotate","matrix","skewX","skewY"] { numeric = numeric.replacingOccurrences(of:operation,with:"") }
                numeric = numeric.replacingOccurrences(of:"(",with:" ").replacingOccurrences(of:")",with:" ")
            }
            if key == "d" {
                let commands = Set("MmZzLlHhVvCcSsQqTtAa")
                numeric = String(numeric.map { commands.contains($0) ? " " : $0 })
            }
            // Insert a separator before signs except an exponent sign; SVG permits 1-2.
            numeric = numeric.replacingOccurrences(of:"(?<![eE])(?=[+-])",with:" ",options:.regularExpression)
            let numbers = numeric.split { $0 == " " || $0 == "," || $0 == "\n" || $0 == "\r" || $0 == "\t" }
            tokens += numbers.count
            guard tokens <= 40_000, !numbers.isEmpty,
                  numbers.allSatisfy({ Double($0).map { $0.isFinite && abs($0) <= 1_000_000 } ?? false }) else { reject(parser); return }
            if depth == 1, ["width","height"].contains(key) {
                guard let size = Double(value),size >= 1,size <= 16384 else { reject(parser); return }
                if key == "width" { dimensions.0 = Int(size) } else { dimensions.1 = Int(size) }
            }
        }
        if depth == 1 {
            let scale = min(1,1024/Double(max(dimensions.0,dimensions.1)))
            dimensions = (max(1,Int(Double(dimensions.0)*scale)),max(1,Int(Double(dimensions.1)*scale)))
        }
    }
    func parser(_ parser:XMLParser,didEndElement:String,namespaceURI:String?,qualifiedName:String?) { depth -= 1 }
    func parser(_ parser:XMLParser,foundCharacters text:String) { if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { reject(parser) } }
    func parser(_ parser:XMLParser,foundProcessingInstructionWithTarget target:String,data:String?) { reject(parser) }
    private func reject(_ parser:XMLParser) { invalid = true; parser.abortParsing() }
}

/// One renderer is used for catalog, editor and applied wallpaper. Three/four
/// colors use a smooth corner mesh; phase advances placements like the reference.
public enum TelegramWallpaperRenderer {
    public static func render(colors:TelegramWallpaperColors,pattern:Data? = nil,intensity:Int = 0,width:Int = 256,height:Int = 512) throws -> CGImage {
        guard colors.isValid,(-100...100).contains(intensity),(1...1024).contains(width),(1...1024).contains(height) else { throw TelegramAppearanceError.image }
        var mask: [UInt8]?
        if let pattern {
            guard let image = TelegramWallpaperPattern.normalizedImage(pattern) else { throw TelegramAppearanceError.image }
            var bytes = [UInt8](repeating:0,count:width*height*4)
            let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image,in:CGRect(x:0,y:0,width:width,height:height)); return true
            }
            guard success else { throw TelegramAppearanceError.image }; mask = bytes
        }
        let rgb = colors.colors.map { [Double(($0>>16)&255),Double(($0>>8)&255),Double($0&255)] }
        let radians = Double(colors.rotation)*Double.pi/180, dx = sin(radians),dy = cos(radians)
        let span = max(0.001,abs(dx)+abs(dy))
        var bytes = [UInt8](repeating:255,count:width*height*4)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let u = Double(x)/Double(max(1,width-1)),v = Double(y)/Double(max(1,height-1)),index = (y*width+x)*4
                let weights: [Double]
                if rgb.count == 1 { weights = [1] }
                else if rgb.count == 2 { let t = min(1,max(0,0.5+((u-0.5)*dx+(v-0.5)*dy)/span)); weights = [1-t,t] }
                else { let a = u*u*(3-2*u),b = v*v*(3-2*v); weights = [(1-a)*(1-b),a*(1-b),a*b,(1-a)*b] }
                let opacity = Double(mask?[index+3] ?? 0)/255*Double(abs(intensity))/100
                for c in 0..<3 {
                    var value = 0.0
                    for (corner,weight) in weights.enumerated() { value += rgb[(corner+colors.phase)%rgb.count][c]*weight }
                    let overlay = 0.0
                    bytes[index+c] = UInt8(min(255,max(0,(value*(1-opacity)+overlay*opacity).rounded())))
                }
            }
        }
        guard let provider = CGDataProvider(data:Data(bytes) as CFData),let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { throw TelegramAppearanceError.image }
        return image
    }
}
