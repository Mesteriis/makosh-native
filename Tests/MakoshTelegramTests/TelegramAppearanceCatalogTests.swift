import XCTest
import TelegramApi
@testable import MakoshTelegram

final class TelegramAppearanceCatalogTests: XCTestCase {
    func testDesktopPaletteImportsColorsWithoutFollowingWallpaperURL() throws {
        let data = Data("name = Synthetic\nisDark = 1\naccent = #123456\nbackground = #102030\ntext = #ddeeff\nbubbleBackground_incoming = #203040\nbubbleBackground_outgoing = #aabbcc,#ffeedd\nwallpaper = https://invalid.example/never-fetch\n".utf8)
        let value = try TelegramCloudPalette.parse(data)
        XCTAssertEqual(value.name,"Synthetic"); XCTAssertTrue(value.isDark)
        XCTAssertEqual(value.accent,0x123456); XCTAssertEqual(value.background,0x102030)
        XCTAssertEqual(value.outgoing,[0xaabbcc,0xffeedd])
        XCTAssertEqual(value.text,0xddeeff)
    }
    func testMalformedDuplicateOrOversizedPaletteIsRefused() {
        for text in ["name=X\nisDark=1\naccent=#zzzzzz", "name=X\nisDark=2\naccent=#123456", "name=X\nisDark=0\naccent=#123456\naccent=#ffffff", "name=X\nisDark=0\naccent=#123456:1.5", "name=X\nisDark=0", "name=X\nisDark=0\naccent=+fffff"] {
            XCTAssertThrowsError(try TelegramCloudPalette.parse(Data(text.utf8)))
        }
        XCTAssertThrowsError(try TelegramCloudPalette.parse(Data(repeating:32,count:1_048_577)))
    }
    func testNativeCatalogMapsActualSettingsAndRejectsNotModifiedAsIncomplete() throws {
        let setting = Api.ThemeSettings.themeSettings(flags:0,baseTheme:.baseThemeNight,accentColor:Int32(bitPattern:0xff123456),outboxAccentColor:nil,messageColors:[0xaabbcc],wallpaper:nil)
        let theme = Api.Theme.theme(flags:0,id:7,accessHash:9,slug:"test",title:"Synthetic",document:nil,settings:[setting],emoticon:nil,installsCount:nil)
        let colors = Api.WallPaperSettings.wallPaperSettings(flags:0,backgroundColor:0x123456,secondBackgroundColor:0xabcdef,thirdBackgroundColor:nil,fourthBackgroundColor:nil,intensity:nil,rotation:0,emoticon:nil)
        let mapped = try XCTUnwrap(telegramAppearanceCatalog(themes:.themes(hash:0,themes:[theme]),wallpapers:.wallPapers(hash:0,wallpapers:[.wallPaperNoFile(id:10,flags:0,settings:colors)]),accountID:1))
        XCTAssertEqual(mapped.snapshot.accountID,1); XCTAssertEqual(mapped.snapshot.choices.count,2)
        guard case let .theme(value) = mapped.snapshot.choices[0].kind else { return XCTFail("Missing native theme") }
        XCTAssertTrue(value.isDark); XCTAssertEqual(value.accent,0x123456)
        XCTAssertEqual(mapped.snapshot.choices[1].kind,.wallpaper(.colors(.init(colors:[0x123456,0xabcdef]))))
        XCTAssertNil(telegramAppearanceCatalog(themes:.themesNotModified,wallpapers:.wallPapers(hash:0,wallpapers:[]),accountID:1))
        XCTAssertNil(telegramAppearanceCatalog(themes:.themes(hash:0,themes:[theme,theme]),wallpapers:.wallPapers(hash:0,wallpapers:[]),accountID:1))
    }
}
@MainActor final class TelegramAppearanceCatalogControllerTests: XCTestCase {
    private final class Request: TelegramSessionsRequest { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramAppearanceCatalogProvider {
        let accountID: Int64 = 1
        var reads: [(Request,@MainActor (Result<TelegramAppearanceCatalogSnapshot,TelegramAppearanceError>) -> Void)] = []
        var downloads: [(Request,@MainActor (Result<TelegramCloudAppearanceKind,TelegramAppearanceError>) -> Void)] = []
        func load(receive: @escaping @MainActor (Result<TelegramAppearanceCatalogSnapshot,TelegramAppearanceError>) -> Void) -> any TelegramSessionsRequest { let r = Request(); reads.append((r,receive)); return r }
        func prepare(_ choice: TelegramCloudAppearanceChoice, receive: @escaping @MainActor (Result<TelegramCloudAppearanceKind,TelegramAppearanceError>) -> Void) -> any TelegramSessionsRequest { let r = Request(); downloads.append((r,receive)); return r }
    }
    func testSelectionRequiresCurrentSnapshotAndClosingRejectsLatePreparation() {
        let c = TelegramAppearanceCatalogController(), p = Provider()
        let choice = TelegramCloudAppearanceChoice(id:"wallpaper:9",title:"Test",kind:.downloadWallpaper)
        c.bind(p); c.open(); p.reads[0].1(.success(.init(accountID:1,choices:[choice])))
        let old = c.contextID
        XCTAssertTrue(c.select(choice,contextID:old)); c.close(); XCTAssertTrue(p.downloads[0].0.cancelled)
        p.downloads[0].1(.success(.wallpaper(.solid(0x123456)))); XCTAssertNil(c.prepared)
        c.open(); p.reads[1].1(.success(.init(accountID:1,choices:[choice])))
        XCTAssertFalse(c.select(choice,contextID:old)); XCTAssertNil(c.prepared)
    }
    func testWallpaperPreparationCannotReturnAnUnrelatedTheme() {
        let c = TelegramAppearanceCatalogController(), p = Provider()
        let choice = TelegramCloudAppearanceChoice(id:"wallpaper:9",title:"Test",kind:.downloadWallpaper)
        c.bind(p); c.open(); p.reads[0].1(.success(.init(accountID:1,choices:[choice])))
        XCTAssertTrue(c.select(choice,contextID:c.contextID))
        let palette = TelegramCloudPalette(name:"Unrelated",isDark:false,accent:0x123456,background:nil,text:nil,incoming:nil,outgoing:[])
        p.downloads[0].1(.success(.theme(palette)))
        XCTAssertNil(c.prepared); XCTAssertEqual(c.phase,.failed)
    }
    func testForeignAccountCannotPublishCatalogAndImmediateChoiceNeedsNoFetch() {
        let c = TelegramAppearanceCatalogController(), p = Provider()
        c.bind(p); c.open(); p.reads[0].1(.success(.init(accountID:2,choices:[])))
        XCTAssertEqual(c.phase,.failed); XCTAssertNil(c.snapshot)
        c.open(); let choice = TelegramCloudAppearanceChoice(id:"wallpaper:2",title:"Test",kind:.wallpaper(.solid(0xffffff)))
        p.reads[1].1(.success(.init(accountID:1,choices:[choice])))
        XCTAssertTrue(c.select(choice,contextID:c.contextID)); XCTAssertEqual(c.prepared?.kind,.wallpaper(.solid(0xffffff)))
        XCTAssertEqual(p.downloads.count,0)
    }
}
