import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import MakoshTelegram
@testable import MakoshApp

final class TelegramAppearancePreferencesTests: XCTestCase {
    func testNightScheduleCrossesMidnightWithExactInclusiveStartExclusiveEnd() throws {
        let value = TelegramNightSchedule(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for (hour, minute, expected) in [(21,59,false), (22,0,true), (23,59,true), (0,0,true), (6,59,true), (7,0,false)] {
            let date = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 10, day: 14, hour: hour, minute: minute)))
            XCTAssertEqual(value.isNight(at: date, calendar: calendar), expected)
        }
    }
    func testDaytimeScheduleAndTimezoneUseLocalWallClock() throws {
        let value = TelegramNightSchedule(enabled: true, startMinute: 8 * 60, endMinute: 12 * 60)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        let date = Date(timeIntervalSince1970: 1_600_000_000) // UTC12:26, local14:26; outside8..12.
        XCTAssertFalse(value.isNight(at: date, calendar: calendar))
        calendar.timeZone = TimeZone(secondsFromGMT: -4 * 3600)!
        XCTAssertTrue(value.isNight(at: date, calendar: calendar)) // local08:26.
        XCTAssertFalse(TelegramNightSchedule(enabled: false, startMinute: 0, endMinute: 0).isNight(at: date, calendar: calendar))
    }
    func testMalformedPreferencesCannotInstallPathEscapeInvalidSizeOrSchedule() throws {
        var value = TelegramAppearancePreferences()
        value.fontSize = 19; XCTAssertThrowsError(try value.encoded())
        value.fontSize = 14; value.wallpaper = .image("../private.jpg"); XCTAssertThrowsError(try value.encoded())
        value.wallpaper = .solid(0x1000000); XCTAssertThrowsError(try value.encoded())
        value.wallpaper = .automatic; value.night = .init(enabled: true, startMinute: 60, endMinute: 60)
        XCTAssertThrowsError(try value.encoded())
        XCTAssertThrowsError(try TelegramAppearancePreferences.decode(String(repeating: "x", count: 16_385)))
        XCTAssertThrowsError(try TelegramAppearancePreferences.decode("{\"version\":99}"))
    }
    func testPreferencesRoundTripPreservesLocalWallpaperAndAnimationChoice() throws {
        var value = TelegramAppearancePreferences(); value.fontSize = 18; value.animationsEnabled = false
        value.wallpaper = .gradient(0x123456, 0xaabbcc); value.night = .init(enabled: true, startMinute: 1200, endMinute: 360)
        let restored = try TelegramAppearancePreferences.decode(value.encoded())
        XCTAssertEqual(restored, value)
        XCTAssertEqual(try TelegramAppearancePreferences.decode(""), TelegramAppearancePreferences())
    }
    @MainActor func testMessageFontSizeAppliesToRegularBoldAndCodeWithoutChangingEntities() throws {
        let value = try TelegramFormattedText(text: "bold code", entities: [.init(offset: 0,length: 4,kind: .bold), .init(offset: 5,length: 4,kind: .code)])
        let native = TelegramMessagePresentation.attributedString(value, fontSize: 18)
        XCTAssertEqual((native.attribute(.font, at: 0,effectiveRange: nil) as? NSFont)?.pointSize, 18)
        XCTAssertEqual((native.attribute(.font, at: 5,effectiveRange: nil) as? NSFont)?.pointSize, 18)
        XCTAssertEqual(native.string, "bold code")
        XCTAssertTrue(NSFontManager.shared.traits(of: try XCTUnwrap(native.attribute(.font,at: 0,effectiveRange:nil) as? NSFont)).contains(.boldFontMask))
        let invalid = TelegramMessagePresentation.attributedString(value, fontSize: .nan)
        XCTAssertEqual((invalid.attribute(.font,at: 0,effectiveRange:nil) as? NSFont)?.pointSize, 14)
    }
    func testWallpaperPreparationBoundsPixelsAndStripsMetadata() throws {
        let input = try image(width: 3000, height: 10, metadata: [kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.3, kCGImagePropertyGPSLatitudeRef: "N"], kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "synthetic original metadata"]])
        let original = try XCTUnwrap(CGImageSourceCreateWithData(input as CFData,nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(original,0,nil) as? [CFString:Any])
        XCTAssertEqual((originalProperties[kCGImagePropertyExifDictionary] as? [CFString:Any])?[kCGImagePropertyExifUserComment] as? String,"synthetic original metadata")
        let output = try TelegramWallpaperImage.prepare(input)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(output as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 2560)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        XCTAssertNil((props[kCGImagePropertyExifDictionary] as? [CFString:Any])?[kCGImagePropertyExifUserComment])
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source,0,nil))
    }
    func testWallpaperRejectsMalformedAndOversizedEncodedInput() {
        XCTAssertThrowsError(try TelegramWallpaperImage.prepare(Data("not an image".utf8)))
        XCTAssertThrowsError(try TelegramWallpaperImage.prepare(Data(repeating: 0,count: 32 * 1024 * 1024 + 1)))
    }
    @MainActor func testNightThemeNeverLeaksIntoAnotherService() {
        let night = TelegramNightSchedule(enabled: true, startMinute: 0, endMinute: 1439)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        XCTAssertEqual(telegramWorkspaceScheme(theme: "day", telegramSelected: true, system: .light, night: night, date: date), .dark)
        XCTAssertEqual(telegramWorkspaceScheme(theme: "night", telegramSelected: false, system: .light, night: night, date: date), .light)
    }
    @MainActor func testTypedSpaceReplacesPlainEmoticonButNeverCodeOrPastedSentence() {
        let text = TelegramNativeInput(frame: .init(x:0,y:0,width:400,height:100))
        text.replaceEmoticons = true
        text.string = ":)"; text.setSelectedRange(.init(location:2,length:0))
        text.insertText(" ",replacementRange:.init(location:NSNotFound,length:0))
        XCTAssertEqual(text.string, "🙂 ")
        text.string = ":)"; text.setSelectedRange(.init(location:2,length:0))
        text.textStorage?.addAttribute(.font,value:NSFont.monospacedSystemFont(ofSize:14,weight:.regular),range:.init(location:0,length:2))
        text.insertText(" ",replacementRange:.init(location:NSNotFound,length:0))
        XCTAssertEqual(text.string, ":) ")
        text.string = ""; text.setSelectedRange(.init(location:0,length:0))
        text.insertText("pasted :) ",replacementRange:.init(location:NSNotFound,length:0))
        XCTAssertEqual(text.string, "pasted :) ")
    }
    func testWallpaperFilesRoundTripWithPrivatePermissionsAndNoSymlinkReads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-wallpaper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let prepared = try TelegramWallpaperImage.prepare(image(width:4,height:3,metadata:[:]))
        let name = try TelegramWallpaperFiles.install(prepared,directory:root)
        XCTAssertEqual(try TelegramWallpaperFiles.load(name,directory:root),prepared)
        let permissions = try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue,0o600)
        let alias = UUID().uuidString.lowercased() + ".jpg"
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent(alias),withDestinationURL:root.appendingPathComponent(name))
        XCTAssertThrowsError(try TelegramWallpaperFiles.load(alias,directory:root))
        XCTAssertThrowsError(try TelegramWallpaperFiles.load("../" + name,directory:root))
        XCTAssertEqual(try TelegramWallpaperFiles.readSelection(root.appendingPathComponent(name)),prepared)
        XCTAssertThrowsError(try TelegramWallpaperFiles.readSelection(root.appendingPathComponent(alias)))
    }
    func testWallpaperRefusesPublicOrSymlinkedAssetRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-wallpaper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o755])
        defer { try? FileManager.default.removeItem(at:root) }
        XCTAssertThrowsError(try TelegramWallpaperFiles.install(Data([1]),directory:root))
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-wallpaper-link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
        defer { try? FileManager.default.removeItem(at:link) }
        XCTAssertThrowsError(try TelegramWallpaperFiles.install(Data([1]),directory:link))
    }
    func testScheduledNightPaletteDoesNotCarryNightTextAndBubblesIntoDay() {
        var value = TelegramAppearancePreferences()
        value.cloudPalette = .init(name:"Night",isDark:true,accent:0x123456,background:0x102030,text:0xffffff,incoming:0x223344,outgoing:[0x334455])
        value.night.enabled = true
        XCTAssertNil(value.effectivePalette(isDark:false))
        XCTAssertEqual(value.effectivePalette(isDark:true)?.text,0xffffff)
        value.night.enabled = false
        XCTAssertNotNil(value.effectivePalette(isDark:false))
    }
    private func image(width: Int, height: Int, metadata: [CFString: Any]) throws -> Data {
        let context = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2,green:0.4,blue:0.6,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        let data = NSMutableData(), destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination,try XCTUnwrap(context.makeImage()),metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return data as Data
    }
}
