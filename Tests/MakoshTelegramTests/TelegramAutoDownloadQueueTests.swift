import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramAutoDownloadQueueTests: XCTestCase {
    private final class Lease: TelegramMediaLease { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramMediaProvider {
        var callbacks: [String: @MainActor (TelegramMediaEvent) -> Void] = [:]
        var leases: [Lease] = []
        var starts: [String] = []
        func start(attachmentID: String, purpose: TelegramMediaPurpose,
                   receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            let lease = Lease(); leases.append(lease); starts.append(attachmentID); callbacks[attachmentID] = receive; return lease
        }
        func startAutomatically(attachmentID: String, preferences: TelegramAutoDownloadPreferences,
            isCurrent: @escaping @MainActor () -> Bool,
            receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            start(attachmentID: attachmentID, purpose: .full, receive: receive)
        }
    }
    private func attachments(_ count: Int = 6) -> [TelegramAttachment] {
        (0..<count).map { .init(id: "file-\($0)", kind: .photo, name: "Synthetic", byteCount: 100,
            mimeType: nil, hasPreview: true, canDownload: true) }
    }
    private func setup() -> (TelegramMediaController, Provider, TelegramAutoDownloadSettings, TelegramAutoDownloadQueue, String) {
        let name = "AutoQueue.\(UUID())", defaults = UserDefaults(suiteName: name)!
        let settings = TelegramAutoDownloadSettings(defaults: defaults); settings.bind(accountID: 11)
        let media = TelegramMediaController(), provider = Provider()
        media.bind(provider: provider); media.retain(attachments: attachments())
        return (media, provider, settings, TelegramAutoDownloadQueue(settings: settings, media: media), name)
    }
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    func testOnlyExplicitlyEnabledVisibleWorkStartsWithThreeTransferBound() async {
        let (media, provider, settings, queue, name) = setup()
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let context = UUID(); queue.replace(attachments: attachments(), contextID: context, active: true)
        await Task.yield(); XCTAssertTrue(provider.starts.isEmpty)
        var p = settings.preferences; p.enabled = true
        XCTAssertTrue(settings.update(p, contextID: settings.contextID)); await waitUntil { provider.starts.count == 3 }
        XCTAssertEqual(provider.starts, ["file-0", "file-1", "file-2"])
        provider.callbacks["file-0"]?(.data(URL(fileURLWithPath: "/synthetic/file"), offset: 0, size: 100, complete: true))
        await waitUntil { provider.starts.count == 4 }; XCTAssertEqual(provider.starts, ["file-0", "file-1", "file-2", "file-3"])
        XCTAssertEqual(media.phase(for: .init(attachmentID: "file-0", purpose: .full)), .ready)
        queue.replace(attachments: [], contextID: context, active: false); await waitUntil { provider.leases.allSatisfy(\.cancelled) }
        XCTAssertTrue(provider.leases.allSatisfy(\.cancelled))
    }
    func testDisablingOrLeavingViewportDoesNotCancelManualDownload() async {
        let (media, provider, settings, queue, name) = setup()
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        media.start(attachments()[0], purpose: .full)
        var p = settings.preferences; p.enabled = true; _ = settings.update(p, contextID: settings.contextID)
        queue.replace(attachments: attachments(), contextID: UUID(), active: true); await waitUntil { provider.starts.count >= 3 }
        await waitUntil { provider.starts.count == 4 }; XCTAssertEqual(provider.starts.count, 4)
        p.enabled = false; _ = settings.update(p, contextID: settings.contextID); await waitUntil { provider.leases.dropFirst().allSatisfy(\.cancelled) }
        XCTAssertFalse(provider.leases[0].cancelled)
        XCTAssertTrue(provider.leases.dropFirst().allSatisfy(\.cancelled))
        XCTAssertEqual(media.phase(for: .init(attachmentID: "file-0", purpose: .full)), .downloading(nil))
    }
    func testFailureDoesNotCreateAutomaticRetryLoopAndOldCompletionCannotResurrect() async {
        let (media, provider, settings, queue, name) = setup()
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        var p = settings.preferences; p.enabled = true; _ = settings.update(p, contextID: settings.contextID)
        let context = UUID(); queue.replace(attachments: attachments(), contextID: context, active: true); await waitUntil { provider.starts.count == 3 }
        let old = provider.callbacks["file-0"]
        old?(.failed); await waitUntil { provider.starts.count == 4 }
        XCTAssertEqual(provider.starts.filter { $0 == "file-0" }.count, 1)
        queue.replace(attachments: attachments(), contextID: context, active: true); await Task.yield()
        XCTAssertEqual(provider.starts.filter { $0 == "file-0" }.count, 1)
        queue.replace(attachments: [], contextID: UUID(), active: false); await waitUntil { provider.leases.allSatisfy(\.cancelled) }
        old?(.data(URL(fileURLWithPath: "/synthetic/stale"), offset: 0, size: 100, complete: true))
        XCTAssertNil(media.downloadedFile(for: .init(attachmentID: "file-0", purpose: .full)))
    }
    func testPolicyRevocationBeforeQueuedCancellationRejectsCompletionAndArchiveCallback() async {
        let (media, provider, settings, queue, name) = setup()
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        var archived = 0; media.completedFullFile = { _,_,_ in archived += 1 }
        var p = settings.preferences; p.enabled = true; _ = settings.update(p, contextID: settings.contextID)
        queue.replace(attachments: attachments(), contextID: UUID(), active: true); await waitUntil { provider.starts.count >= 3 }
        p.enabled = false; _ = settings.update(p, contextID: settings.contextID)
        provider.callbacks["file-0"]?(.data(URL(fileURLWithPath: "/synthetic/late"), offset: 0, size: 100, complete: true))
        XCTAssertNil(media.downloadedFile(for: .init(attachmentID: "file-0", purpose: .full)))
        XCTAssertEqual(archived, 0)
    }
    func testArchiveCapacityPausesReplacementDownloadsAndWakeResumesWithoutDiscardingAdmittedCompletions() async {
        let (media, provider, settings, queue, name) = setup()
        defer { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        let budget = ArchiveBudget()
        media.reserveAutomaticFile = { budget.reserve($0) }
        var p = settings.preferences; p.enabled = true; _ = settings.update(p, contextID: settings.contextID)
        queue.replace(attachments: attachments(), contextID: UUID(), active: true)
        await waitUntil { provider.starts.count == 3 }
        for id in provider.starts { provider.callbacks[id]?(.data(URL(fileURLWithPath: "/synthetic/file"), offset: 0, size: 100, complete: true)) }
        await Task.yield()
        XCTAssertEqual(budget.captured, ["file-0", "file-1", "file-2"])
        XCTAssertEqual(provider.starts.count, 3)
        budget.release("file-0"); queue.archiveCapacityChanged()
        await waitUntil { provider.starts.count == 4 }
        XCTAssertEqual(provider.starts.last, "file-3")
        queue.replace(attachments: [], contextID: UUID(), active: false)
        await waitUntil { provider.leases.allSatisfy(\.cancelled) }
        XCTAssertEqual(Set(budget.held), ["file-1", "file-2"], "Captured handoffs survive viewport exit; uncompleted admission is released")
    }
    @MainActor private final class ArchiveBudget {
        var held = Set<String>(), captured: [String] = []
        func reserve(_ id: String) -> (any TelegramMediaArchiveReservation)? {
            guard held.count < 3 else { return nil }; held.insert(id); return Reservation(owner: self, id: id)
        }
        func release(_ id: String) { held.remove(id) }
        private final class Reservation: TelegramMediaArchiveReservation {
            let owner: ArchiveBudget, id: String
            var consumed = false
            init(owner: ArchiveBudget, id: String) { self.owner = owner; self.id = id }
            func capture(file: URL, byteCount: Int64) -> Bool { guard !consumed else { return false }; consumed = true; owner.captured.append(id); return true }
            func cancel() { if !consumed { consumed = true; owner.release(id) } }
        }
    }
}
