import XCTest
@testable import MakoshTelegram

@MainActor final class TelegramTransferManagementTests: XCTestCase {
    private final class Lease: TelegramMediaLease { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramMediaProvider {
        var jobs: [(String,Lease,@MainActor (TelegramMediaEvent) -> Void)] = []
        func start(attachmentID:String,purpose:TelegramMediaPurpose,receive:@escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            let lease = Lease(); jobs.append((attachmentID,lease,receive)); return lease
        }
        func startAutomatically(attachmentID:String,preferences:TelegramAutoDownloadPreferences,isCurrent:@escaping @MainActor () -> Bool,receive:@escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            start(attachmentID:attachmentID,purpose:.full,receive:receive)
        }
    }
    private func attachment(_ id: String = "file") -> TelegramAttachment {
        .init(id:id,kind:.photo,name:"Synthetic.png",byteCount:4,mimeType:"image/png",hasPreview:true,canDownload:true)
    }
    private func setup() -> (TelegramMediaController,Provider) {
        let media = TelegramMediaController(), provider = Provider(); media.bind(provider:provider); media.retain(attachments:[attachment()]); return (media,provider)
    }
    func testTransferListIncludesFullJobsAndExcludesPreviewOwnership() throws {
        let (media,_) = setup(); media.start(attachment(),purpose:.preview); media.start(attachment(),purpose:.full)
        XCTAssertEqual(media.transfers.count,1)
        XCTAssertEqual(media.transfers.first?.attachment.name,"Synthetic.png")
        XCTAssertEqual(media.transfers.first?.key.purpose,.full)
    }
    func testStaleCancelCannotControlRestartedTransferWithSameAttachmentID() throws {
        let (media,p) = setup(); media.start(attachment(),purpose:.full)
        let old = try XCTUnwrap(media.transfers.first)
        XCTAssertTrue(media.cancelTransfer(old)); XCTAssertTrue(p.jobs[0].1.cancelled)
        let cancelled = try XCTUnwrap(media.transfers.first)
        XCTAssertTrue(media.retryTransfer(cancelled)); XCTAssertEqual(p.jobs.count,2)
        guard p.jobs.count == 2 else { return }
        XCTAssertFalse(media.cancelTransfer(old)); XCTAssertFalse(p.jobs[1].1.cancelled)
        p.jobs[0].2(.data(URL(fileURLWithPath:"/synthetic/old"),offset:0,size:4,complete:true))
        XCTAssertEqual(media.transfers.first?.phase,.downloading(nil))
    }
    func testStaleExportAndErrorCannotBorrowOrInvalidateNewAccountFile() async throws {
        let (media,p) = setup(); media.start(attachment(),purpose:.full)
        p.jobs[0].2(.data(URL(fileURLWithPath:"/synthetic/old"),offset:0,size:4,complete:true))
        let old = try XCTUnwrap(media.transfers.first), next = Provider()
        media.bind(provider:next); media.retain(attachments:[attachment()]); media.start(attachment(),purpose:.full)
        next.jobs[0].2(.data(URL(fileURLWithPath:"/synthetic/new"),offset:0,size:4,complete:true))
        var borrowed = false
        let accepted = try await media.withDownloadedFile(for:old.key,transfer:old) { _,_ in borrowed = true }
        XCTAssertFalse(accepted); XCTAssertFalse(borrowed)
        XCTAssertFalse(media.invalidateTransfer(old)); XCTAssertEqual(media.transfers.first?.phase,.ready)
        XCTAssertFalse(next.jobs[0].1.cancelled)
    }
    func testBorrowedSourceSurvivesResetUntilOriginalExportFinishes() async throws {
        let (media,p) = setup(); media.start(attachment(),purpose:.full)
        p.jobs[0].2(.data(URL(fileURLWithPath:"/synthetic/original"),offset:0,size:4,complete:true))
        let transfer = try XCTUnwrap(media.transfers.first)
        let started = expectation(description:"borrowed original"), finished = expectation(description:"finished original")
        let stream = AsyncStream<Void>.makeStream()
        let task = Task { @MainActor in
            let accepted = try await media.withDownloadedFile(for:transfer.key,transfer:transfer) { url,size in
                XCTAssertEqual(url.path,"/synthetic/original"); XCTAssertEqual(size,4); started.fulfill()
                var iterator = stream.stream.makeAsyncIterator(); _ = await iterator.next()
            }
            XCTAssertTrue(accepted); finished.fulfill()
        }
        await fulfillment(of:[started],timeout:2); media.reset(); XCTAssertFalse(p.jobs[0].1.cancelled)
        stream.continuation.yield(()); stream.continuation.finish()
        await fulfillment(of:[finished],timeout:2); try await task.value
        XCTAssertTrue(p.jobs[0].1.cancelled)
    }
    func testClearingFinishedListReleasesReadyLeaseAndPreservesActiveManualWork() throws {
        let (media,p) = setup(); media.retain(attachments:[attachment(),attachment("other")])
        media.start(attachment(),purpose:.full); p.jobs[0].2(.data(URL(fileURLWithPath:"/synthetic/ready"),offset:0,size:4,complete:true))
        media.start(attachment("other"),purpose:.full)
        let context = media.transferContextID
        XCTAssertTrue(media.clearFinishedTransfers(contextID:context))
        XCTAssertTrue(p.jobs[0].1.cancelled); XCTAssertFalse(p.jobs[1].1.cancelled)
        XCTAssertEqual(media.transfers.count,1); XCTAssertEqual(media.transfers.first?.attachment.id,"other")
        media.reset(); XCTAssertFalse(media.clearFinishedTransfers(contextID:context))
    }
    func testPauseCancelsOnlyAutomaticWorkAndResumeUsesCurrentPolicy() async {
        let name = "TransferPause." + UUID().uuidString
        let defaults = UserDefaults(suiteName:name)!
        defer { defaults.removePersistentDomain(forName:name) }
        let settings = TelegramAutoDownloadSettings(defaults:defaults); settings.bind(accountID:11)
        var prefs = settings.preferences; prefs.enabled = true; _ = settings.update(prefs,contextID:settings.contextID)
        let (media,p) = setup(), queue = TelegramAutoDownloadQueue(settings:settings,media:media)
        let values = [attachment(),attachment("other")]; media.retain(attachments:values); media.start(values[0],purpose:.full)
        queue.replace(attachments:values,contextID:UUID(),active:true)
        await waitUntil { p.jobs.count == 2 }
        queue.setPaused(true); await waitUntil { p.jobs[1].1.cancelled }
        XCTAssertFalse(p.jobs[0].1.cancelled)
        prefs.enabled = false; _ = settings.update(prefs,contextID:settings.contextID)
        queue.setPaused(false); for _ in 0..<20 { await Task.yield() }; XCTAssertEqual(p.jobs.count,2)
        prefs.enabled = true; _ = settings.update(prefs,contextID:settings.contextID)
        await waitUntil { p.jobs.count == 3 }; XCTAssertFalse(p.jobs[0].1.cancelled)
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by:.seconds(3))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }; XCTAssertTrue(predicate())
    }
}
