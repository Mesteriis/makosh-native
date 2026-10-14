import XCTest
import CoreGraphics
import ImageIO
import TelegramApi
import MtProtoKit
import Darwin
@testable import MakoshTelegram

final class TelegramWallpaperVariantTests: XCTestCase {
    private let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\"><path fill=\"#000000\" d=\"M0 0H8V16H0Z\"/></svg>".utf8)
    func testFourColorWallpaperRoundTripAndLegacyPreferences() throws {
        let colors = TelegramWallpaperColors(colors:[0xff0000,0x00ff00,0x0000ff,0xffffff],phase:2)
        var p = TelegramAppearancePreferences(); p.wallpaper = .colors(colors)
        XCTAssertEqual(try TelegramAppearancePreferences.decode(p.encoded()),p)
        p.wallpaper = .pattern(.init(name:UUID().uuidString.lowercased()+".png",colors:colors,intensity:-60))
        XCTAssertEqual(try TelegramAppearancePreferences.decode(p.encoded()),p)
        for old: TelegramLocalWallpaper in [.automatic,.solid(0xabcdef),.gradient(0xff0000,0x0000ff),.image(UUID().uuidString+".jpg")] {
            p.wallpaper = old; XCTAssertEqual(try TelegramAppearancePreferences.decode(p.encoded()).wallpaper,old)
        }
        p.wallpaper = .colors(.init(colors:[1,2,3],rotation:45)); XCTAssertThrowsError(try p.encoded())
        p.wallpaper = .colors(.init(colors:[1,2],rotation:46)); XCTAssertThrowsError(try p.encoded())
    }
    func testPatternMalformedExternalAndComplexityRefusal() throws {
        let normalized = try TelegramWallpaperPattern.prepare(svg)
        let image = try XCTUnwrap(CGImageSourceCreateWithData(normalized as CFData,nil))
        XCTAssertEqual(CGImageSourceGetCount(image),1)
        for invalid in ["<!DOCTYPE svg [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><svg>&e;</svg>",
            "<svg><image href='https://invalid.example/a'/></svg>","<svg><script/></svg>",
            "<svg width='16' height='16'><path style='fill:url(https://invalid.example)'/></svg>",
            "<svg width='1000000' height='1'/>","<svg><path d='M NaN 0'/></svg>",
            "<svg>"+String(repeating:"<g>",count:34)+String(repeating:"</g>",count:34)+"</svg>",
            "<svg><path d='"+String(repeating:"M0 0",count:20001)+"'/></svg>"] {
            XCTAssertThrowsError(try TelegramWallpaperPattern.prepare(Data(invalid.utf8)),invalid.prefix(80).description)
        }
        XCTAssertThrowsError(try TelegramWallpaperPattern.prepare(Data(repeating:0,count:2_097_153)))
    }
    func testPatternIntensityAndRotationPixels() throws {
        let mask = try TelegramWallpaperPattern.prepare(svg)
        let colors = TelegramWallpaperColors(colors:[0xff0000,0x0000ff])
        let plain = try TelegramWallpaperRenderer.render(colors:colors,width:16,height:16)
        let zero = try TelegramWallpaperRenderer.render(colors:colors,pattern:mask,intensity:0,width:16,height:16)
        XCTAssertEqual(plain.dataProvider?.data as Data?,zero.dataProvider?.data as Data?)
        let dark = try TelegramWallpaperRenderer.render(colors:colors,pattern:mask,intensity:100,width:16,height:16)
        let light = try TelegramWallpaperRenderer.render(colors:colors,pattern:mask,intensity:-100,width:16,height:16)
        XCTAssertNotEqual(dark.dataProvider?.data as Data?,plain.dataProvider?.data as Data?)
        XCTAssertNotEqual(dark.dataProvider?.data as Data?,light.dataProvider?.data as Data?)
        let rotated = try TelegramWallpaperRenderer.render(colors:.init(colors:colors.colors,rotation:90),width:16,height:16)
        XCTAssertNotEqual(rotated.dataProvider?.data as Data?,plain.dataProvider?.data as Data?)
        let corners = try TelegramWallpaperRenderer.render(colors:.init(colors:[0xff0000,0x00ff00,0x0000ff,0xffffff]),width:3,height:3)
        let pixels = try XCTUnwrap(corners.dataProvider?.data) as Data
        XCTAssertEqual(Array(pixels.prefix(4)),[255,0,0,255])
        XCTAssertEqual(Array(pixels.suffix(4)),[0,0,255,255])
        XCTAssertThrowsError(try TelegramWallpaperRenderer.render(colors:colors,width:100000,height:100000))
    }
    func testPaletteAlphaSurvivesPersistenceAndRendering() throws {
        let palette = try TelegramCloudPalette.parse(Data("name=Alpha\nisDark=0\naccent=#123456:0.5\nbackground=#ffffff:0.25\ntext=#000000:0.75\nbubbleBackground_outgoing=#aabbcc:0.3,#ffffff:0.6".utf8))
        var p = TelegramAppearancePreferences(); p.cloudPalette = palette
        let copy = try XCTUnwrap(TelegramAppearancePreferences.decode(p.encoded()).cloudPalette)
        XCTAssertEqual(copy.color("accent",rgb:copy.accent).alpha,0.5,accuracy:0.001)
        XCTAssertEqual(copy.color("background",rgb:0xffffff).alpha,0.25,accuracy:0.001)
        XCTAssertEqual(copy.color("outgoing.1",rgb:0xffffff).alpha,0.6,accuracy:0.001)
        for alpha in ["nan","inf","-0.1","1.01"] { XCTAssertThrowsError(try TelegramCloudPalette.parse(Data("name=X\nisDark=0\naccent=#ffffff:\(alpha)".utf8))) }
    }
    func testGzipExactStreamAndOutputBounds() throws {
        let hex = "1f8b08000000000002ffb3292e4b57a8c8cdc92bb655ca282929b0d2d72f2f2fd72b37d6cb2f4ad737323030d007aa505228cf4c29c9b05532345352c848cd4ccf2801b3ed6c0a124b3214d23273726c95940dc0404921c556c9d740c1c0c322ccd0ccc3204a49dfce0664881d0095b169056c000000"
        let bytes = stride(from:0,to:hex.count,by:2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex,offsetBy:offset); return UInt8(hex[start..<hex.index(start,offsetBy:2)],radix:16)!
        }
        let zipped = Data(bytes)
        XCTAssertEqual(try TelegramWallpaperPattern.prepare(zipped),try TelegramWallpaperPattern.prepare(svg))
        XCTAssertThrowsError(try TelegramWallpaperPattern.prepare(zipped+zipped))
        XCTAssertThrowsError(try TelegramWallpaperPattern.prepare(zipped.dropLast()))
    }
    func testPatternPrivateAtomicInstallAndLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let png = try TelegramWallpaperPattern.prepare(svg)
        let name = try TelegramWallpaperFiles.installPattern(png,directory:directory)
        XCTAssertTrue(name.hasSuffix(".png")); XCTAssertEqual(try TelegramWallpaperFiles.loadPattern(name,directory:directory),png)
        let mode = try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent(name).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode,0o600)
        XCTAssertThrowsError(try TelegramWallpaperFiles.installPattern(Data("bad".utf8),directory:directory))
        XCTAssertThrowsError(try TelegramWallpaperFiles.loadPattern("../other.png",directory:directory))
    }
    func testSpecialSelectionIsRefusedWithoutWaitingForWriter() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertEqual(mkfifo(path,0o600),0); defer { unlink(path) }
        DispatchQueue.global().asyncAfter(deadline:.now()+0.3) {
            let writer = open(path,O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
            if writer >= 0 { close(writer) }
        }
        let start = Date()
        XCTAssertThrowsError(try TelegramWallpaperFiles.readSelection(URL(fileURLWithPath:path)))
        XCTAssertLessThan(Date().timeIntervalSince(start),0.2)
    }
    func testCloudPatternUsesBoundedDecoderAndMapsFourColors() throws {
        let settings = Api.WallPaperSettings.wallPaperSettings(flags:0,backgroundColor:1,secondBackgroundColor:2,thirdBackgroundColor:3,fourthBackgroundColor:4,intensity:60,rotation:90,emoticon:nil)
        let file = Api.Document.document(flags:0,id:1,accessHash:2,fileReference:Buffer(data:Data()),date:0,mimeType:"application/x-tgwallpattern",size:Int64(svg.count),thumbs:nil,videoThumbs:nil,dcId:2,attributes:[])
        let mapped = try XCTUnwrap(telegramAppearanceCatalog(themes:.themes(hash:0,themes:[]),wallpapers:.wallPapers(hash:0,wallpapers:[.wallPaperNoFile(id:3,flags:0,settings:settings),.wallPaper(id:4,flags:8,accessHash:2,slug:"safe",document:file,settings:settings)]),accountID:1))
        XCTAssertEqual(mapped.snapshot.choices[0].kind,.wallpaper(.colors(.init(colors:[1,2,3,4]))))
        XCTAssertEqual(mapped.snapshot.choices[1].kind,.downloadWallpaper)
        let source = try XCTUnwrap(mapped.resources["wallpaper:4"])
        guard case let .pattern(value) = try telegramPrepareAppearance(svg,source:source) else { return XCTFail("Missing normalized pattern") }
        XCTAssertEqual(value.colors.colors,[1,2,3,4]); XCTAssertEqual(value.intensity,60)
        XCTAssertThrowsError(try telegramPrepareAppearance(Data("<svg><image href='file:///x'/></svg>".utf8),source:source))
    }
}
