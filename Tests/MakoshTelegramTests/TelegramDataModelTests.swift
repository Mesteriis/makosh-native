import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramDataModelTests: XCTestCase {
    private final class Lease: TelegramMediaLease { func cancel() {} }
    private final class Provider: TelegramMediaProvider {
        var callbacks: [String: @MainActor (TelegramMediaEvent) -> Void] = [:]
        func start(attachmentID: String, purpose: TelegramMediaPurpose, receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease { Lease() }
        func startAutomatically(attachmentID: String, preferences: TelegramAutoDownloadPreferences, isCurrent: @escaping @MainActor () -> Bool,
            receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            if isCurrent() { callbacks[attachmentID] = receive }; return Lease()
        }
    }
    func testVisibleIncomingMessageAdmissionRejectsLateDataAfterNavigation() async throws {
        let name = "DataModel.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = TelegramModel.syntheticPreview(dataDefaults: defaults, dataSettings: true)
        model.selectedChatID = model.chats.first?.id
        let message = try XCTUnwrap(model.messages.first { !$0.isOutgoing && !$0.attachments.isEmpty })
        let context = try XCTUnwrap(model.historyReadContext), provider = Provider()
        model.media.bind(provider: provider)
        model.media.retain(attachments: model.messages.flatMap(\.attachments))
        var p = model.autoDownloadSettings.preferences; p.enabled = true; p.files.peers = Set(TelegramDownloadPeer.allCases)
        XCTAssertTrue(model.autoDownloadSettings.update(p, contextID: model.autoDownloadSettings.contextID))
        model.setVisibleAutomaticDownloads(messageIDs: [message.id], context: context, windowIsActive: true, eligibility: { true })
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while provider.callbacks.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        let id = try XCTUnwrap(provider.callbacks.keys.first), callback = try XCTUnwrap(provider.callbacks[id])
        model.selectedChatID = model.chats.first { $0.id != context.chatID }?.id
        callback(.data(URL(fileURLWithPath: "/synthetic/stale"), offset: 0, size: 10, complete: true))
        XCTAssertNil(model.media.downloadedFile(for: .init(attachmentID: id, purpose: .full)))
        model.disconnect(); XCTAssertNil(model.autoDownloadSettings.accountID)
    }
    func testCacheClearNeedsReadyAccountAndBusyWorkRevokesFrozenConsent() throws {
        let name = "DataCache.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = TelegramModel.syntheticPreview(dataDefaults: defaults)
        model.cache.open()
        let choice = try XCTUnwrap(model.cache.prepareClear(categories: [.photos], contextID: model.cache.contextID))
        model.disconnect()
        XCTAssertFalse(model.cache.confirmClear(choice)); XCTAssertNil(model.cache.snapshot)
    }
}
