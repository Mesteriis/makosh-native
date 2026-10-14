import XCTest
import TelegramCore
import MakoshCore
import SwiftSignalKit
@testable import Postbox
@testable import MakoshTelegram

@MainActor final class TelegramBackgroundDownloadTests: XCTestCase {
    private final class Lease: TelegramMediaLease { var cancelled = false; func cancel() { cancelled = true } }
    private final class Provider: TelegramMediaProvider {
        struct Entry { let id: String, purpose: TelegramMediaPurpose; let lease: Lease; let receive: @MainActor (TelegramMediaEvent) -> Void }
        var entries: [Entry] = []
        func start(attachmentID:String,purpose:TelegramMediaPurpose,receive:@escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            let lease = Lease(); entries.append(.init(id:attachmentID,purpose:purpose,lease:lease,receive:receive)); return lease
        }
        func startAutomatically(attachmentID:String,preferences:TelegramAutoDownloadPreferences,isCurrent:@escaping @MainActor () -> Bool,receive:@escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            start(attachmentID:attachmentID,purpose:.full,receive:receive)
        }
    }
    private func attachment(_ id: String) -> TelegramAttachment {
        .init(id:id,kind:.file,name:"Synthetic-\(id).txt",byteCount:4,mimeType:"text/plain",hasPreview:true,canDownload:true)
    }
    func testManualLeaseSurvivesUnrelatedChatRetention() throws {
        let media = TelegramMediaController(), provider = Provider(), original = attachment("chatA-file")
        media.bind(provider:provider); media.retain(attachments:[original]); media.start(original,purpose:.full)
        let transfer = try XCTUnwrap(media.transfers.first), context = media.transferContextID
        media.retain(attachments:[attachment("chatB-file")])
        XCTAssertFalse(provider.entries[0].lease.cancelled)
        XCTAssertEqual(media.transferContextID,context)
        XCTAssertEqual(media.transfers.first?.id,transfer.id)
        provider.entries[0].receive(.data(URL(fileURLWithPath:"/synthetic/chatA-file"),offset:0,size:4,complete:true))
        XCTAssertEqual(media.transfer(for:transfer.key)?.phase,.ready)
        XCTAssertEqual(media.downloadedFile(for:transfer.key)?.lastPathComponent,"chatA-file")
    }
    func testAutomaticPreviewStillCancelOnLeave() {
        let media = TelegramMediaController(), provider = Provider()
        let manual = attachment("manual"), automatic = attachment("automatic"), preview = attachment("preview")
        media.bind(provider:provider); media.retain(attachments:[manual,automatic,preview])
        media.start(manual,purpose:.full); _ = media.startAutomatically(automatic,preferences:.init(),isCurrent:{true}); media.start(preview,purpose:.preview)
        media.retain(attachments:[])
        XCTAssertFalse(provider.entries[0].lease.cancelled)
        XCTAssertTrue(provider.entries[1].lease.cancelled); XCTAssertTrue(provider.entries[2].lease.cancelled)
        XCTAssertEqual(media.transfers.map(\.key.attachmentID),["manual"])
    }
    func testPreviewOfManuallyRetainedFileStillCancelsOnChatLeave() {
        let media = TelegramMediaController(), provider = Provider(), file = attachment("same-file")
        media.bind(provider:provider); media.retain(attachments:[file])
        media.start(file,purpose:.preview); media.start(file,purpose:.full); media.retain(attachments:[])
        XCTAssertTrue(provider.entries[0].lease.cancelled)
        XCTAssertFalse(provider.entries[1].lease.cancelled)
        XCTAssertEqual(media.phase(for:.init(attachmentID:file.id,purpose:.preview)),.idle)
    }
    func testStaleAccountTransferCannotCancelReplacement() throws {
        let media = TelegramMediaController(), provider = Provider(), original = attachment("same")
        media.bind(provider:provider); media.retain(attachments:[original]); media.start(original,purpose:.full)
        let stale = try XCTUnwrap(media.transfers.first)
        let replacement = Provider(); media.bind(provider:replacement); media.retain(attachments:[original]); media.start(original,purpose:.full)
        XCTAssertFalse(media.cancelTransfer(stale)); XCTAssertTrue(provider.entries[0].lease.cancelled)
        provider.entries[0].receive(.data(URL(fileURLWithPath:"/synthetic/stale"),offset:0,size:4,complete:true))
        XCTAssertEqual(media.transfers.first?.phase,.downloading(nil)); XCTAssertFalse(replacement.entries[0].lease.cancelled)
    }
    func testManualRetryPreservesOriginalAttribution() throws {
        let media = TelegramMediaController(), provider = Provider(), original = attachment("chatA-file")
        var captures: [String] = []
        media.bind(provider:provider); media.retain(attachments:[original])
        media.completedFullFile = { _,_,_ in captures.append("chatA") }; media.start(original,purpose:.full)
        provider.entries[0].receive(.failed)
        let failed = try XCTUnwrap(media.transfers.first)
        media.completedFullFile = { _,_,_ in captures.append("chatB") }
        XCTAssertTrue(media.retryTransfer(failed))
        provider.entries[1].receive(.data(URL(fileURLWithPath:"/synthetic/original"),offset:0,size:4,complete:true))
        XCTAssertEqual(captures,["chatA"])
    }
    func testS3OffAtCompletionRefusesCopyAfterLeavingOriginalChat() async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let config = try S3ConfigurationFile.read(URL(fileURLWithPath:XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-background-s3-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try FileManager.default.removeItem(at:root) }
        let spool = root.appendingPathComponent("queue")
        let repository = try ArchiveFileRepository(connectionString:database.connectionString,schema:database.schema,configuration:config,spoolDirectory:spool,keyProvider:{ _,_ in Data(repeating:0x59,count:32) })
        let files = TelegramFileArchiveController(factory:{repository}), media = TelegramMediaController(), provider = Provider()
        let original = attachment("original"), source = root.appendingPathComponent("source")
        let a = MessageArchiveIdentity(service:"telegram",accountID:"11",conversationID:"37",messageID:"0:1")
        let b = MessageArchiveIdentity(service:"telegram",accountID:"11",conversationID:"38",messageID:"0:1")
        let descriptor = MessageArchiveAttachment(id:original.id,kind:"file",name:"Synthetic.txt",size:4)
        try Data("data".utf8).write(to:source)
        media.bind(provider:provider); media.retain(attachments:[original])
        media.completedFullFile = { _,url,size in files.accept(file:url,byteCount:size,identity:a,attachment:descriptor) }
        media.start(original,purpose:.full); media.retain(attachments:[attachment("other-chat")])
        media.completedFullFile = { _,url,size in files.accept(file:url,byteCount:size,identity:b,attachment:descriptor) }
        try await repository.setConversationFileSavingEnabled(identity:a,enabled:false)
        provider.entries[0].receive(.data(source,offset:0,size:4,complete:true))
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while files.isBusy, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(files.isBusy); XCTAssertNil(files.error)
        let originalRecords = try await repository.files(identity:a,attachmentID:original.id)
        let wrongChatRecords = try await repository.files(identity:b,attachmentID:original.id)
        XCTAssertTrue(originalRecords.isEmpty); XCTAssertTrue(wrongChatRecords.isEmpty)
        let staged = (try? FileManager.default.contentsOfDirectory(atPath:spool.path)) ?? []
        XCTAssertTrue(staged.isEmpty)
    }
    @MainActor private final class Deadlines {
        var actions: [@MainActor () -> Void] = []
        func schedule(_ action:@escaping @MainActor () -> Void) -> Task<Void,Never> { actions.append(action); return Task {} }
    }
    func testRealProgressRenewsIdleDeadlineAndOldTimerCannotAbortLargeFile() {
        let deadlines = Deadlines(), provider = Provider(), media = TelegramMediaController(scheduleDeadline:{ action in deadlines.schedule(action) })
        let file = attachment("large")
        media.bind(provider:provider); media.retain(attachments:[file]); media.start(file,purpose:.full)
        let original = deadlines.actions[0]
        provider.entries[0].receive(.progress(0.25))
        XCTAssertEqual(deadlines.actions.count,2)
        original(); XCTAssertEqual(media.transfers.first?.phase,.downloading(0.25)); XCTAssertFalse(provider.entries[0].lease.cancelled)
        guard deadlines.actions.count == 2 else { return }
        provider.entries[0].receive(.progress(0.25)); provider.entries[0].receive(.progress(.nan)); provider.entries[0].receive(.progress(0.1))
        XCTAssertEqual(deadlines.actions.count,2,"Repeated/invalid/backwards progress must not keep a stalled transfer alive")
        deadlines.actions[1](); XCTAssertEqual(media.transfers.first?.phase,.timedOut); XCTAssertTrue(provider.entries[0].lease.cancelled)
    }
    func testGrowingPartialDataRenewsIdleDeadlineWithoutBecomingReady() {
        let deadlines = Deadlines(), provider = Provider(), media = TelegramMediaController(scheduleDeadline:{ action in deadlines.schedule(action) })
        let file = attachment("unknown-size")
        media.bind(provider:provider); media.retain(attachments:[file]); media.start(file,purpose:.full)
        provider.entries[0].receive(.data(URL(fileURLWithPath:"/synthetic/partial"),offset:0,size:4,complete:false))
        XCTAssertEqual(deadlines.actions.count,2)
        deadlines.actions[0](); XCTAssertEqual(media.transfers.first?.phase,.downloading(nil)); XCTAssertNil(media.downloadedFile(for:.init(attachmentID:file.id,purpose:.full)))
        guard deadlines.actions.count == 2 else { return }
        provider.entries[0].receive(.data(URL(fileURLWithPath:"/synthetic/partial"),offset:0,size:4,complete:false))
        XCTAssertEqual(deadlines.actions.count,2)
        deadlines.actions[1](); XCTAssertEqual(media.transfers.first?.phase,.timedOut)
    }
}

@MainActor final class TelegramBackgroundDownloadJournalTests: XCTestCase {
    private func record(_ message: Int32 = 7, state: TelegramDownloadRecord.State = .pending) -> TelegramDownloadRecord {
        .init(attachmentID:"11:0:\(message):file",peerID:11,namespace:0,messageID:message,name:"Synthetic.txt",byteCount:4,photo:false,state:state)
    }
    func testJournalRoundTripAndBounds() throws {
        let value = TelegramDownloadJournalSnapshot(accountID:11,revision:UUID(),records:[record()])
        let bytes = try value.encoded()
        XCTAssertEqual(try TelegramDownloadJournalSnapshot.decode(bytes,accountID:11),value)
        XCTAssertThrowsError(try TelegramDownloadJournalSnapshot.decode(bytes,accountID:22))
        var invalid = value; invalid.records = Array(repeating:record(),count:2)
        XCTAssertThrowsError(try invalid.encoded())
        invalid.records = (1...1001).map { record(Int32($0)) }
        XCTAssertThrowsError(try invalid.encoded())
        invalid.records = [record()]; invalid.version = 2; XCTAssertThrowsError(try invalid.encoded())
        var bad = record(); bad.peerID = 22; invalid.version = 1; invalid.records = [bad]
        XCTAssertThrowsError(try invalid.encoded())
        XCTAssertThrowsError(try TelegramDownloadJournalSnapshot.decode(Data(repeating:0,count:2_097_153),accountID:11))
    }
    private final class Request: TelegramDownloadJournalRequest { func cancel() {} }
    private final class Repository: TelegramDownloadJournalRepository {
        let accountID: Int64
        var snapshot: TelegramDownloadJournalSnapshot?
        var hold = false, fail = false
        var writes: [(TelegramDownloadJournalSnapshot,UUID?,@MainActor (Result<Void,TelegramDownloadJournalError>) -> Void)] = []
        init(_ account: Int64 = 11) { accountID = account }
        func load(completion:@escaping @MainActor (Result<TelegramDownloadJournalSnapshot?,TelegramDownloadJournalError>) -> Void) -> any TelegramDownloadJournalRequest {
            completion(.success(snapshot)); return Request()
        }
        func save(_ value:TelegramDownloadJournalSnapshot,expected:UUID?,completion:@escaping @MainActor (Result<Void,TelegramDownloadJournalError>) -> Void) {
            writes.append((value,expected,completion)); if !hold { completeLast() }
        }
        func completeLast() {
            let value = writes.last!
            guard !fail else { value.2(.failure(.unavailable)); return }
            guard snapshot?.revision == value.1 else { value.2(.failure(.changed)); return }
            snapshot = value.0; value.2(.success(()))
        }
    }
    func testSerializedMutationsDoNotDropEarlierRecord() {
        let repository = Repository(), journal = TelegramDownloadJournal()
        journal.bind(repository:repository); repository.hold = true
        var acknowledgements: [Bool] = []
        journal.upsert(record()) { acknowledgements.append($0) }
        journal.upsert(record(8)) { acknowledgements.append($0) }
        XCTAssertEqual(repository.writes.count,1); XCTAssertEqual(journal.records,[]); XCTAssertTrue(acknowledgements.isEmpty)
        repository.completeLast(); XCTAssertEqual(repository.writes.count,2)
        repository.completeLast()
        XCTAssertEqual(journal.records.map(\.messageID),[7,8]); XCTAssertEqual(acknowledgements,[true,true])
        XCTAssertEqual(repository.writes[1].1,repository.writes[0].0.revision)
    }
    func testPersistenceFailureVisibleAndNoFalseAcknowledgement() {
        let repository = Repository(), journal = TelegramDownloadJournal(); journal.bind(repository:repository)
        repository.fail = true; var acknowledged = true
        journal.upsert(record()) { acknowledged = $0 }
        XCTAssertFalse(acknowledged); XCTAssertNotNil(journal.error); XCTAssertEqual(journal.records,[])
        repository.fail = false; journal.reload()
        journal.upsert(record()) { acknowledged = $0 }
        XCTAssertTrue(acknowledged); XCTAssertNil(journal.error); XCTAssertEqual(journal.records.count,1)
    }
    func testAccountRebindIgnoresLateWrite() {
        let old = Repository(), journal = TelegramDownloadJournal(); old.hold = true; journal.bind(repository:old)
        journal.upsert(record()) { _ in }
        let replacement = Repository(22); journal.bind(repository:replacement)
        old.completeLast()
        XCTAssertEqual(journal.accountID,22); XCTAssertEqual(journal.records,[]); XCTAssertNil(journal.error)
    }
    func testFinishedRemovalPersistsAndCannotOverwriteOtherWriter() {
        let repository = Repository(), journal = TelegramDownloadJournal(); journal.bind(repository:repository)
        journal.upsert(record(state:.ready)) { XCTAssertTrue($0) }
        journal.remove(ids:["11:0:7:file"]) { XCTAssertTrue($0) }
        XCTAssertEqual(journal.records,[]); XCTAssertNotNil(repository.snapshot?.revision)
        repository.snapshot = .init(accountID:11,revision:UUID(),records:[record(9)])
        journal.upsert(record(8)) { XCTAssertFalse($0) }
        XCTAssertNotNil(journal.error); XCTAssertEqual(repository.snapshot?.records.map(\.messageID),[9])
    }
    private final class MediaProvider: TelegramMediaProvider {
        final class Lease: TelegramMediaLease { var cancelled = false; func cancel() { cancelled = true } }
        var entries: [(Lease,@MainActor (TelegramMediaEvent) -> Void)] = []
        var fetches = 0, cachedReads = 0
        func start(attachmentID:String,purpose:TelegramMediaPurpose,receive:@escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            fetches += 1; let lease = Lease(); entries.append((lease,receive)); return lease
        }
        func startCached(attachmentID:String,receive:@escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            cachedReads += 1; let lease = Lease(); entries.append((lease,receive)); return lease
        }
    }
    private func configured(_ repository: Repository) -> (TelegramMediaController,MediaProvider,TelegramDownloadJournal) {
        let media = TelegramMediaController(), provider = MediaProvider(), journal = TelegramDownloadJournal()
        journal.bind(repository:repository); media.bind(provider:provider)
        media.configureJournal(journal,recordFor:{ attachment,state in
            .init(attachmentID:attachment.id,peerID:11,namespace:0,messageID:7,name:attachment.name,byteCount:attachment.byteCount,photo:false,state:state)
        })
        media.retain(attachments:[record().placeholder]); return (media,provider,journal)
    }
    func testManualDownloadWaitsForDurableIntentThenStarts() {
        let repository = Repository(); repository.hold = true
        let (media,provider,_) = configured(repository)
        media.start(record().placeholder,purpose:.full)
        XCTAssertEqual(media.transfers.first?.phase,.queued); XCTAssertEqual(provider.entries.count,0)
        XCTAssertEqual(media.inFlightCount,1,"Queued manual intent must also block cache removal")
        repository.completeLast()
        XCTAssertEqual(media.transfers.first?.phase,.downloading(nil)); XCTAssertEqual(provider.entries.count,1)
    }
    func testCancelledQueuedIntentNeverStartsOnLateAcknowledgement() throws {
        let repository = Repository(); repository.hold = true
        let (media,provider,journal) = configured(repository)
        media.start(record().placeholder,purpose:.full)
        XCTAssertTrue(media.cancelTransfer(try XCTUnwrap(media.transfers.first)))
        repository.completeLast(); XCTAssertEqual(provider.entries.count,0)
        repository.completeLast()
        XCTAssertEqual(journal.records.first?.state,.cancelled)
        XCTAssertEqual(media.transfers.first?.phase,.cancelled)
    }
    func testFourManualFetchesRunAndFifthWaits() {
        let media = TelegramMediaController(), provider = MediaProvider()
        let attachments = (1...5).map { record(Int32($0)).placeholder }
        media.bind(provider:provider); media.retain(attachments:attachments)
        for attachment in attachments { media.start(attachment,purpose:.full) }
        XCTAssertEqual(provider.entries.count,4)
        XCTAssertEqual(media.phase(for:.init(attachmentID:"11:0:5:file",purpose:.full)),.queued)
        provider.entries[0].1(.data(URL(fileURLWithPath:"/synthetic/first"),offset:0,size:4,complete:true))
        XCTAssertEqual(provider.entries.count,5)
        XCTAssertEqual(media.phase(for:.init(attachmentID:"11:0:5:file",purpose:.full)),.downloading(nil))
    }
    func testPersistenceFailurePreventsNetworkFetchAndIsVisible() throws {
        let repository = Repository(); repository.fail = true
        let (media,provider,_) = configured(repository)
        media.start(record().placeholder,purpose:.full)
        XCTAssertEqual(provider.entries.count,0); XCTAssertNotNil(media.queueError)
        XCTAssertEqual(media.transfers.first?.phase,.failed)
        repository.fail = false; media.retryQueuePersistence()
        XCTAssertTrue(media.retryTransfer(try XCTUnwrap(media.transfers.first)))
        XCTAssertNil(media.queueError); XCTAssertEqual(provider.entries.count,1)
    }
    func testQueuedWritesOutliveTheCallingView() {
        let repository = Repository(); repository.hold = true
        var journal: TelegramDownloadJournal? = TelegramDownloadJournal(); journal!.bind(repository:repository)
        journal!.upsert(record()) { XCTAssertTrue($0) }
        journal!.upsert(record(state:.cancelled)) { XCTAssertTrue($0) }
        weak var retained = journal; journal = nil
        XCTAssertNotNil(retained)
        repository.completeLast(); XCTAssertEqual(repository.writes.count,2)
        repository.completeLast(); XCTAssertEqual(repository.snapshot?.records.first?.state,.cancelled)
        repository.writes.removeAll(); XCTAssertNil(retained)
    }
    func testRejectedMutationCannotLoseAlreadyCommittingValidWrite() {
        let repository = Repository(), journal = TelegramDownloadJournal(); repository.hold = true; journal.bind(repository:repository)
        journal.upsert(record()) { XCTAssertTrue($0) }
        var invalid = record(); invalid.peerID = 22
        journal.upsert(invalid) { XCTAssertFalse($0) }
        repository.completeLast()
        XCTAssertEqual(journal.records.map(\.messageID),[7])
    }
    func testActualPostboxCASAndUnknownFormatPreserveExistingJournal() async throws {
        let box = try await telegramDataPostbox(test:self)
        let value = TelegramDownloadJournalSnapshot(accountID:11,revision:UUID(),records:[record()])
        let results = try await telegramDataValue(backgroundJournalCAS(box,value:value),test:self)
        XCTAssertEqual(results,[true,true,true,true])
    }
    func testProductionRepositoryReadsAndWritesOnItsActualPostboxQueue() async throws {
        let box = try await telegramDataPostbox(test:self)
        let repository = TelegramPostboxDownloadJournalRepository(postbox:box,accountID:11), journal = TelegramDownloadJournal()
        let loaded = expectation(description:"native journal read"), saved = expectation(description:"native journal commit")
        journal.didLoad = { _ in loaded.fulfill() }; journal.bind(repository:repository)
        await fulfillment(of:[loaded],timeout:3)
        XCTAssertTrue(journal.isReady)
        journal.upsert(record()) { result in XCTAssertTrue(result); saved.fulfill() }
        await fulfillment(of:[saved],timeout:3)
        XCTAssertEqual(journal.records.map(\.messageID),[7])
    }
    func testRestoredReadyUsesOnlyCacheAndExplicitRetryMayFetch() throws {
        let media = TelegramMediaController(), provider = MediaProvider(); media.bind(provider:provider)
        media.restoreManual(attachment:record().placeholder,state:.ready,completedFile:nil)
        XCTAssertEqual(provider.cachedReads,1); XCTAssertEqual(provider.fetches,0)
        provider.entries[0].1(.failed)
        XCTAssertTrue(media.retryTransfer(try XCTUnwrap(media.transfers.first)))
        XCTAssertEqual(provider.cachedReads,1); XCTAssertEqual(provider.fetches,1)
    }
    func testRestoredCancellationWaitsAndExistingTransferIsNeverReplaced() throws {
        let media = TelegramMediaController(), provider = MediaProvider(); media.bind(provider:provider)
        media.restoreManual(attachment:record().placeholder,state:.cancelled,completedFile:nil)
        XCTAssertEqual(provider.entries.count,0); XCTAssertEqual(media.transfers.first?.phase,.cancelled)
        XCTAssertTrue(media.retryTransfer(try XCTUnwrap(media.transfers.first)))
        let active = try XCTUnwrap(media.transfers.first)
        media.restoreManual(attachment:record().placeholder,state:.ready,completedFile:nil)
        XCTAssertEqual(media.transfers.first?.id,active.id); XCTAssertEqual(provider.entries.count,1)
    }
    func testLateCleanupFailureCannotSetErrorOnReplacementAccount() {
        let repository = Repository(), (media,provider,_) = configured(repository)
        media.start(record().placeholder,purpose:.full)
        provider.entries[0].1(.data(URL(fileURLWithPath:"/synthetic/ready"),offset:0,size:4,complete:true))
        repository.hold = true; XCTAssertTrue(media.clearFinishedTransfers(contextID:media.transferContextID))
        media.bind(provider:MediaProvider()); repository.fail = true; repository.completeLast()
        XCTAssertNil(media.queueError)
    }
    func testActualCachedProviderRefusesMissingAndProtectsExistingResource() async throws {
        let box = try await telegramDataPostbox(test:self)
        let seeded = try await telegramDataValue(seedBackgroundDownload(box),test:self)
        let source = try XCTUnwrap(seeded), provider = TelegramEngineMediaProvider(postbox:box)
        provider.sources = [source.attachment.id:source]
        let missing = expectation(description:"missing cache refused")
        let missingLease = provider.startCached(attachmentID:source.attachment.id) { event in
            if case .failed = event { missing.fulfill() }
            if case .fetchCompleted = event { XCTFail("A completed record must never initiate a new fetch") }
        }
        await fulfillment(of:[missing],timeout:3); missingLease.cancel()
        let resource = try XCTUnwrap(source.full?.resource)
        box.mediaBox.storeResourceData(resource.id,data:Data(repeating:0x59,count:100),synchronous:true)
        let ready = expectation(description:"real cache lease restored")
        let readyLease = provider.startCached(attachmentID:source.attachment.id) { event in
            if case let .data(_,offset,size,complete) = event, complete { XCTAssertEqual(offset,0); XCTAssertEqual(size,100); ready.fulfill() }
            if case .failed = event { XCTFail("Valid cached data must restore") }
        }
        await fulfillment(of:[ready],timeout:3)
        let removed = try await telegramDataValue(box.mediaBox.removeCachedResourcesWithResult([resource.id],force:false,notify:true),test:self)
        XCTAssertTrue(removed.isEmpty); XCTAssertEqual(box.mediaBox.resourceUsage(id:resource.id),100)
        readyLease.cancel()
    }
    func testRestoreContextCannotResurrectExplicitlyClearedTransfer() {
        let media = TelegramMediaController(), provider = MediaProvider(), attachment = record().placeholder
        media.bind(provider:provider); media.retain(attachments:[attachment]); media.start(attachment,purpose:.full)
        provider.entries[0].1(.data(URL(fileURLWithPath:"/synthetic/ready"),offset:0,size:4,complete:true))
        let stale = media.restorationContextID
        XCTAssertTrue(media.clearFinishedTransfers(contextID:media.transferContextID))
        media.restoreManual(attachment:attachment,state:.ready,completedFile:nil,contextID:stale)
        XCTAssertEqual(media.transfers,[]); XCTAssertEqual(provider.cachedReads,0)
        let beforeRebind = media.restorationContextID
        media.bind(provider:MediaProvider())
        media.restoreManual(attachment:attachment,state:.pending,completedFile:nil,contextID:beforeRebind)
        XCTAssertEqual(media.transfers,[])
    }
    func testProductionDriverRestoresCommittedCacheAndRefusesChangedSource() async throws {
        let box = try await telegramDataPostbox(test:self)
        let seeded = try await telegramDataValue(seedBackgroundDownload(box),test:self), source = try XCTUnwrap(seeded)
        let record = TelegramDownloadRecord(attachmentID:source.attachment.id,peerID:37,namespace:0,messageID:1,name:"Synthetic.bin",byteCount:100,photo:false,state:.ready)
        let stored = try await telegramDataValue(storeBackgroundJournal(box,value:.init(accountID:11,revision:UUID(),records:[record])),test:self)
        XCTAssertTrue(stored)
        let resource = try XCTUnwrap(source.full?.resource)
        box.mediaBox.storeResourceData(resource.id,data:Data(repeating:0x59,count:100),synchronous:true)
        let media = TelegramMediaController(), provider = TelegramEngineMediaProvider(postbox:box)
        media.bind(provider:provider); var completedPeers: [Int64] = []
        var driver: TelegramEngineDownloadJournal? = TelegramEngineDownloadJournal(postbox:box,accountID:11,media:media,provider:provider,completedFile:{ record,attachment,url,size in
            completedPeers.append(record.peerID); XCTAssertEqual(attachment.name,"Synthetic.bin"); XCTAssertTrue(url.isFileURL); XCTAssertEqual(size,100)
        })
        await waitUntil { media.transfers.first?.phase == .ready }
        XCTAssertEqual(completedPeers,[37]); XCTAssertEqual(driver?.journal.accountID,11)
        driver = nil; media.reset()
        _ = try await telegramDataValue(seedBackgroundDownload(box,size:200),test:self)
        let replacement = TelegramEngineMediaProvider(postbox:box); media.bind(provider:replacement)
        driver = TelegramEngineDownloadJournal(postbox:box,accountID:11,media:media,provider:replacement,completedFile:{ _,_,_,_ in XCTFail("A changed source must not capture") })
        await waitUntil { media.transfers.first?.phase == .failed }
        XCTAssertNotNil(media.queueError); XCTAssertEqual(driver?.journal.accountID,11)
        driver = nil; media.reset()
    }
    func testCancelledMissingSourceKeepsCancellationOnRestore() async throws {
        let box = try await telegramDataPostbox(test:self)
        let seeded = try await telegramDataValue(seedBackgroundDownload(box),test:self), source = try XCTUnwrap(seeded)
        let record = TelegramDownloadRecord(attachmentID:source.attachment.id,peerID:37,namespace:0,messageID:1,name:"Synthetic.bin",byteCount:100,photo:false,state:.cancelled)
        let stored = try await telegramDataValue(storeBackgroundJournal(box,value:.init(accountID:11,revision:UUID(),records:[record])),test:self)
        XCTAssertTrue(stored)
        _ = try await telegramDataValue(seedBackgroundDownload(box,size:200),test:self)
        let media = TelegramMediaController(), provider = TelegramEngineMediaProvider(postbox:box); media.bind(provider:provider)
        let driver = TelegramEngineDownloadJournal(postbox:box,accountID:11,media:media,provider:provider,completedFile:{ _,_,_,_ in XCTFail("Cancelled intent cannot capture") })
        await waitUntil { !media.transfers.isEmpty }
        XCTAssertEqual(media.transfers.first?.phase,.cancelled)
        XCTAssertEqual(driver.journal.records.first?.state,.cancelled)
        media.reset()
    }
    func testRecoveredSourceRetryRestoresOriginalArchiveHandler() async throws {
        let box = try await telegramDataPostbox(test:self)
        let seeded = try await telegramDataValue(seedBackgroundDownload(box),test:self), source = try XCTUnwrap(seeded)
        let record = TelegramDownloadRecord(attachmentID:source.attachment.id,peerID:37,namespace:0,messageID:1,name:"Synthetic.bin",byteCount:100,photo:false,state:.pending)
        let stored = try await telegramDataValue(storeBackgroundJournal(box,value:.init(accountID:11,revision:UUID(),records:[record])),test:self)
        XCTAssertTrue(stored)
        _ = try await telegramDataValue(seedBackgroundDownload(box,size:200),test:self)
        let media = TelegramMediaController(), provider = TelegramEngineMediaProvider(postbox:box); media.bind(provider:provider)
        var captures: [Int64] = []
        let driver = TelegramEngineDownloadJournal(postbox:box,accountID:11,media:media,provider:provider,completedFile:{ record,_,_,_ in captures.append(record.peerID) })
        await waitUntil { media.transfers.first?.phase == .failed && !media.isQueueSaving }
        _ = try await telegramDataValue(seedBackgroundDownload(box),test:self)
        let resource = try XCTUnwrap(source.full?.resource)
        box.mediaBox.storeResourceData(resource.id,data:Data(repeating:0x59,count:100),synchronous:true)
        media.retryQueuePersistence(); await waitUntil { !media.isQueueLoading }
        XCTAssertTrue(media.retryTransfer(try XCTUnwrap(media.transfers.first)))
        await waitUntil { media.transfers.first?.phase == .ready }
        XCTAssertEqual(captures,[37]); XCTAssertEqual(driver.journal.accountID,11)
        media.reset()
    }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while !predicate(), ContinuousClock.now < deadline { await Task.yield() }; XCTAssertTrue(predicate())
    }
    func testRestartChangedOrProtectedSourceRefusesInsteadOfGuessingResource() async throws {
        let box = try await telegramDataPostbox(test:self)
        let seeded = try await telegramDataValue(seedBackgroundDownload(box),test:self)
        let source = try XCTUnwrap(seeded)
        let record = TelegramDownloadRecord(attachmentID:source.attachment.id,peerID:37,namespace:0,messageID:1,name:"Synthetic.bin",byteCount:100,photo:false,state:.pending)
        let initial = try await telegramDataValue(resolveBackgroundDownload(box,record:record),test:self)
        XCTAssertEqual(initial?.attachment.byteCount,100)
        _ = try await telegramDataValue(seedBackgroundDownload(box,size:200),test:self)
        let changed = try await telegramDataValue(resolveBackgroundDownload(box,record:record),test:self)
        XCTAssertNil(changed)
        _ = try await telegramDataValue(seedBackgroundDownload(box,protected:true),test:self)
        let protected = try await telegramDataValue(resolveBackgroundDownload(box,record:record),test:self)
        XCTAssertNil(protected)
    }
}

private nonisolated func backgroundJournalCAS(_ box:Postbox,value:TelegramDownloadJournalSnapshot) -> Signal<[Bool],NoError> {
    box.transaction { tx in
        let first = telegramDownloadJournalWrite(transaction:tx,value:value,expected:nil)
        let second = telegramDownloadJournalWrite(transaction:tx,value:.init(accountID:11,revision:UUID(),records:[]),expected:nil)
        let loaded = telegramDownloadJournalRead(transaction:tx,accountID:11)
        var unknown = value; unknown.version = 2
        guard let bytes = try? JSONEncoder().encode(unknown) else { return [] }
        tx.setPreferencesEntry(key:telegramDownloadJournalKey(accountID:11),value:PreferencesEntry(data:bytes))
        let refused = telegramDownloadJournalWrite(transaction:tx,value:value,expected:value.revision)
        return [first.isSuccess, !second.isSuccess, (try? loaded.get()) == value,
            !refused.isSuccess && tx.getPreferencesEntry(key:telegramDownloadJournalKey(accountID:11))?.data == bytes]
    }
}
private extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}
private nonisolated func seedBackgroundDownload(_ box:Postbox,size:Int64 = 100,protected:Bool = false) -> Signal<TelegramAttachmentSource?,NoError> {
    box.transaction { tx in
        let peer = PeerId(37), id = MessageId(peerId:PeerId(37),namespace:0,id:1)
        let user = TelegramUser(id:peer,accessHash:nil,firstName:"Synthetic",lastName:nil,username:nil,phone:nil,photo:[],botInfo:nil,restrictionInfo:nil,flags:[],emojiStatus:nil,usernames:[],storiesHidden:nil,nameColor:nil,backgroundEmojiId:nil,profileColor:nil,profileBackgroundEmojiId:nil,subscriberCount:nil,verificationIconFileId:nil)
        tx.updatePeersInternal([user],update:{ _,new in new })
        let file = TelegramMediaFile(fileId:.init(namespace:Namespaces.Media.CloudFile,id:100),partialReference:nil,
            resource:CloudDocumentMediaResource(datacenterId:2,fileId:100,accessHash:53,size:size,fileReference:Data([1,2]),fileName:"Synthetic.bin"),previewRepresentations:[],videoThumbnails:[],immediateThumbnailData:nil,mimeType:"application/octet-stream",size:size,attributes:[.FileName(fileName:"Synthetic.bin")],alternativeRepresentations:[])
        let message = StoreMessage(id:id,globallyUniqueId:nil,groupingKey:nil,threadId:nil,timestamp:100,
            flags:protected ? [.Incoming,.CopyProtected] : [.Incoming],tags:[],globalTags:[],localTags:[],forwardInfo:nil,authorId:peer,text:"Synthetic",attributes:[],media:[file])
        if tx.getMessage(id) == nil { _ = tx.addMessages([message],location:.Random) }
        else { tx.updateMessage(id) { _ in .update(message) } }
        return tx.getMessage(id).flatMap { telegramAttachments($0).first }
    }
}
private nonisolated func resolveBackgroundDownload(_ box:Postbox,record:TelegramDownloadRecord) -> Signal<TelegramAttachmentSource?,NoError> {
    box.transaction { telegramDownloadSource(transaction:$0,accountID:11,record:record) }
}
private nonisolated func storeBackgroundJournal(_ box:Postbox,value:TelegramDownloadJournalSnapshot) -> Signal<Bool,NoError> {
    box.transaction { telegramDownloadJournalWrite(transaction:$0,value:value,expected:nil).isSuccess }
}
