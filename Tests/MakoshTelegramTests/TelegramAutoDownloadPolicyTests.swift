import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramAutoDownloadPolicyTests: XCTestCase {
    private func attachment(size: Int64? = 100, spoiler: Bool = false, video: Bool = false) -> TelegramAttachment {
        .init(id: "fixture", kind: video ? .file : .photo, name: "Synthetic", byteCount: size,
              mimeType: nil, hasPreview: true, canDownload: true, playback: video ? .video : nil, isSpoiler: spoiler)
    }
    func testExplicitEnableAndCategoryPeerSelectionGateFullDownload() {
        var preferences = TelegramAutoDownloadPreferences()
        XCTAssertFalse(preferences.allows(attachment(), peer: .contacts))
        preferences.enabled = true
        XCTAssertTrue(preferences.allows(attachment(), peer: .contacts))
        preferences.photos.peers.remove(.groups)
        XCTAssertFalse(preferences.allows(attachment(), peer: .groups))
        XCTAssertTrue(preferences.allows(attachment(), peer: .privateChats))
        preferences.videos.peers = []
        XCTAssertFalse(preferences.allows(attachment(video: true), peer: .contacts))
    }
    func testUnknownNegativeOversizedOrSpoilerContentNeverAutoDownloads() {
        var p = TelegramAutoDownloadPreferences(); p.enabled = true; p.photos.limit = 1024
        XCTAssertTrue(p.allows(attachment(size: 1024), peer: .contacts))
        for size: Int64? in [nil, -1, 0, 1025, Int64.max] {
            XCTAssertFalse(p.allows(attachment(size: size), peer: .contacts))
        }
        XCTAssertFalse(p.allows(attachment(spoiler: true), peer: .contacts))
        let paid = TelegramAttachment(id: "paid", kind: .unsupported, name: "Synthetic", byteCount: 1,
            mimeType: nil, hasPreview: false, canDownload: false)
        XCTAssertFalse(p.allows(paid, peer: .contacts))
    }
    func testStorageIsAccountScopedAndRejectsOldEditorAfterRebinding() {
        let name = "MakoshAutoDownloadTests.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = TelegramAutoDownloadSettings(defaults: defaults); first.bind(accountID: 11)
        let old = first.contextID
        var preferences = first.preferences; preferences.enabled = true; preferences.files.limit = 4096
        XCTAssertTrue(first.update(preferences, contextID: old))
        let reopened = TelegramAutoDownloadSettings(defaults: defaults); reopened.bind(accountID: 11)
        XCTAssertTrue(reopened.preferences.enabled); XCTAssertEqual(reopened.preferences.files.limit, 4096)
        first.bind(accountID: 12)
        XCTAssertFalse(first.preferences.enabled)
        XCTAssertFalse(first.update(preferences, contextID: old))
        reopened.bind(accountID: nil)
        XCTAssertFalse(reopened.update(preferences, contextID: reopened.contextID))
    }
    func testCorruptOrWrongTypeRecordRequiresExplicitReset() {
        let name = "MakoshAutoDownloadTests.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for value: Any in [Data("broken".utf8), "wrong type", Data(repeating: 1, count: 65_537)] {
            defaults.set(value, forKey: "telegram.autoDownload.v1.11")
            let settings = TelegramAutoDownloadSettings(defaults: defaults); settings.bind(accountID: 11)
            XCTAssertNotNil(settings.error); XCTAssertFalse(settings.preferences.enabled)
            var p = settings.preferences; p.enabled = true
            XCTAssertFalse(settings.update(p, contextID: settings.contextID))
            XCTAssertTrue(settings.reset(contextID: settings.contextID))
            XCTAssertNil(settings.error); XCTAssertFalse(settings.preferences.enabled)
        }
    }
    func testInvalidLimitCannotBeSavedOrGrantDownload() {
        let name = "MakoshAutoDownloadTests.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = TelegramAutoDownloadSettings(defaults: defaults); settings.bind(accountID: 11)
        var p = settings.preferences; p.enabled = true; p.photos.limit = Int64.max
        XCTAssertFalse(p.allows(attachment(), peer: .contacts))
        XCTAssertFalse(settings.update(p, contextID: settings.contextID))
    }
}
