import XCTest
import MakoshCore
@testable import MakoshTelegram

@MainActor final class TelegramBackgroundDownloadArchiveTests: XCTestCase {
    private final class Provider: TelegramMediaProvider {
        final class Lease: TelegramMediaLease { func cancel() {} }
        var events: [@MainActor (TelegramMediaEvent) -> Void] = []
        func start(attachmentID:String,purpose:TelegramMediaPurpose,receive:@escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
            events.append(receive); return Lease()
        }
    }
    @MainActor private final class Slots {
        var available = 1
        var captured: [String] = []
        func reserve(_ identity:String) -> (any TelegramMediaArchiveReservation)? {
            guard available > 0 else { return nil }; available -= 1
            return Reservation(owner:self,identity:identity)
        }
        final class Reservation: TelegramMediaArchiveReservation {
            private let owner: Slots, identity: String
            private var used = false
            init(owner:Slots,identity:String) { self.owner = owner; self.identity = identity }
            func capture(file:URL,byteCount:Int64) -> Bool {
                guard !used else { return false }; used = true; owner.captured.append(identity); return true
            }
            func cancel() { guard !used else { return }; used = true; owner.available += 1 }
        }
    }
    private func file(_ id:String) -> TelegramAttachment {
        .init(id:id,kind:.file,name:"Synthetic.txt",byteCount:4,mimeType:"text/plain",hasPreview:false,canDownload:true)
    }
    func testManualArchiveCapacityPausesNextFetchAndResumesOnStorageSignal() {
        let media = TelegramMediaController(), provider = Provider(), slots = Slots()
        let a = file("a"), b = file("b")
        media.bind(provider:provider); media.retain(attachments:[a,b])
        media.reserveManualFile = { slots.reserve($0) }
        media.completedFullFile = { _,_,_ in XCTFail("A reserved capture must not also call the unreserved fallback") }
        media.start(a,purpose:.full); media.start(b,purpose:.full)
        XCTAssertEqual(provider.events.count,1)
        XCTAssertEqual(media.phase(for:.init(attachmentID:"b",purpose:.full)),.queued)
        provider.events[0](.data(URL(fileURLWithPath:"/synthetic/a"),offset:0,size:4,complete:true))
        XCTAssertEqual(slots.captured,["a"]); XCTAssertEqual(provider.events.count,1)
        slots.available = 1; media.archiveCapacityChanged()
        XCTAssertEqual(provider.events.count,2)
        XCTAssertEqual(media.phase(for:.init(attachmentID:"b",purpose:.full)),.downloading(nil))
        media.cancel(.init(attachmentID:"b",purpose:.full)); XCTAssertEqual(slots.available,1)
    }
    func testManualArchiveRecipeStaysWithOriginalChatOnRetry() throws {
        let media = TelegramMediaController(), provider = Provider(), slots = Slots(), original = file("original")
        media.bind(provider:provider); media.retain(attachments:[original])
        media.reserveManualFile = { id in slots.reserve("chatA:" + id) }
        media.start(original,purpose:.full); provider.events[0](.failed)
        media.retain(attachments:[file("other-chat")])
        media.reserveManualFile = { id in slots.reserve("chatB:" + id) }
        XCTAssertTrue(media.retryTransfer(try XCTUnwrap(media.transfers.first)))
        provider.events[1](.data(URL(fileURLWithPath:"/synthetic/original"),offset:0,size:4,complete:true))
        XCTAssertEqual(slots.captured,["chatA:original"])
    }
    @MainActor private final class Backend { var repository: ArchiveFileRepository? }
    private final class DeferredReservation: TelegramMediaArchiveReservation {
        var completion: (@MainActor (Bool) -> Void)?
        func capture(file:URL,byteCount:Int64) -> Bool { XCTFail("An asynchronous archive must use its completion boundary"); return false }
        func capture(file:URL,byteCount:Int64,completion:@escaping @MainActor (Bool) -> Void) { self.completion = completion }
        func cancel() {}
    }
    func testWaitingArchiveKeepsTransferActiveAndLateCompletionCannotAffectReplacementAccount() throws {
        let media = TelegramMediaController(), provider = Provider(), reservation = DeferredReservation(), attachment = file("held")
        media.bind(provider:provider); media.retain(attachments:[attachment]); media.reserveManualFile = { _ in reservation }
        media.start(attachment,purpose:.full)
        provider.events[0](.data(URL(fileURLWithPath:"/synthetic/held"),offset:0,size:4,complete:true))
        XCTAssertEqual(media.transfers.first?.phase,.capturing); XCTAssertEqual(media.inFlightCount,1)
        XCTAssertTrue(media.cancelTransfer(try XCTUnwrap(media.transfers.first)))
        media.bind(provider:Provider()); reservation.completion?(true)
        XCTAssertTrue(media.transfers.isEmpty); XCTAssertNil(media.queueError)
    }
    func testCompleteFileCanBeExportedWhileItsArchiveWaits() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-capturing-export-\(UUID())")
        try Data("data".utf8).write(to:source); defer { try? FileManager.default.removeItem(at:source) }
        let media = TelegramMediaController(), provider = Provider(), reservation = DeferredReservation(), attachment = file("complete")
        media.bind(provider:provider); media.retain(attachments:[attachment]); media.reserveManualFile = { _ in reservation }
        media.start(attachment,purpose:.full); provider.events[0](.data(source,offset:0,size:4,complete:true))
        XCTAssertEqual(media.transfers.first?.phase,.capturing)
        let borrowed = try await media.withDownloadedFile(for:.init(attachmentID:attachment.id,purpose:.full),transfer:media.transfers.first) { url,size in
            XCTAssertEqual(size,4); XCTAssertEqual(try Data(contentsOf:url),Data("data".utf8))
        }
        XCTAssertTrue(borrowed)
        reservation.completion?(true); XCTAssertEqual(media.transfers.first?.phase,.ready)
    }
    func testEightReservedManualCapturesSurvivePressureAndFailureThenSaveExactBytes() async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath:XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-manual-capture-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("source"); try Data("data".utf8).write(to:source)
        let backend = Backend(), controller = TelegramFileArchiveController(factory:{
            guard let repository = backend.repository else { throw S3ObjectStoreError.configuration }; return repository
        })
        func identity(_ index:Int) -> MessageArchiveIdentity { .init(service:"telegram",accountID:"11",conversationID:"37",messageID:"0:\(index)") }
        func attachment(_ index:Int) -> MessageArchiveAttachment { .init(id:"synthetic-\(index)",kind:"file",name:"Synthetic.txt",size:4) }
        var reservations: [(Int,any TelegramMediaArchiveReservation)] = []
        for index in 1...8 { reservations.append((index,try XCTUnwrap(controller.reserveManualCapture(identity:identity(index),attachment:attachment(index))))) }
        XCTAssertNil(controller.reserveManualCapture(identity:identity(9),attachment:attachment(9)))
        reservations[0].1.cancel()
        reservations[0] = (9,try XCTUnwrap(controller.reserveManualCapture(identity:identity(9),attachment:attachment(9))))
        // A direct legacy capture cannot steal already reserved manual capacity.
        controller.accept(file:source,byteCount:4,identity:identity(99),attachment:attachment(99))
        XCTAssertNotNil(controller.error)
        for (_,reservation) in reservations { XCTAssertTrue(reservation.capture(file:source,byteCount:4)) }
        try FileManager.default.removeItem(at:source)
        let repository = try ArchiveFileRepository(connectionString:database.connectionString,schema:database.schema,configuration:configuration,spoolDirectory:root.appendingPathComponent("queue"),keyProvider:{ _,_ in Data(repeating:0x59,count:32) })
        backend.repository = repository; controller.retry()
        let deadline = ContinuousClock.now.advanced(by:.seconds(10))
        while controller.isBusy, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(controller.isBusy); XCTAssertNil(controller.error)
        for (index,_) in reservations {
            let records = try await repository.files(identity:identity(index),attachmentID:attachment(index).id)
            XCTAssertEqual(records.count,1)
            if let record = records.first {
                let destination = root.appendingPathComponent("restored-\(index)")
                try await repository.export(record,to:destination); XCTAssertEqual(try Data(contentsOf:destination),Data("data".utf8))
            }
        }
        let pressure = try await repository.files(identity:identity(99),attachmentID:attachment(99).id)
        XCTAssertTrue(pressure.isEmpty)
    }
    func testDisabledChatFinishesWhileOtherManualS3CopiesAreBlocked() async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath:XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-disabled-background-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("source"); try Data("data".utf8).write(to:source)
        let backend = Backend(), controller = TelegramFileArchiveController(factory:{
            guard let repository = backend.repository else { throw S3ObjectStoreError.configuration }; return repository
        })
        for index in 1...8 {
            controller.accept(file:source,byteCount:4,identity:.init(service:"telegram",accountID:"11",conversationID:"37",messageID:"0:\(index)"),
                attachment:.init(id:"blocked-\(index)",kind:"file",name:"Synthetic.txt",size:4))
        }
        XCTAssertNotNil(controller.error)
        let spool = root.appendingPathComponent("queue")
        let repository = try ArchiveFileRepository(connectionString:database.connectionString,schema:database.schema,configuration:configuration,spoolDirectory:spool,keyProvider:{ _,_ in Data(repeating:0x59,count:32) })
        backend.repository = repository
        let identity = MessageArchiveIdentity(service:"telegram",accountID:"11",conversationID:"38",messageID:"0:1")
        try await repository.setConversationFileSavingEnabled(identity:identity,enabled:false)
        let attachment = file("off"), media = TelegramMediaController(), provider = Provider()
        media.bind(provider:provider); media.retain(attachments:[attachment])
        media.reserveManualFile = { _ in controller.reserveManualCapture(identity:identity,attachment:.init(id:"off",kind:"file",name:"Synthetic.txt",size:4)) }
        media.start(attachment,purpose:.full)
        XCTAssertEqual(provider.events.count,1)
        guard provider.events.count == 1 else { return }
        provider.events[0](.data(source,offset:0,size:4,complete:true))
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while media.transfers.first?.phase != .ready, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(media.transfers.first?.phase,.ready)
        let records = try await repository.files(identity:identity,attachmentID:"off")
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath:spool.path)) ?? []).isEmpty)
    }
    func testSwitchingS3OffDuringCapacityWaitAutomaticallyRechecksPolicy() async throws {
        let database = try PendingFilesTestDatabase(); addTeardownBlock { try database.cleanup() }
        let configuration = try S3ConfigurationFile.read(URL(fileURLWithPath:XCTUnwrap(ProcessInfo.processInfo.environment["MAKOSH_TEST_S3_CONFIG"])))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-waiting-policy-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        addTeardownBlock { try FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("source"); try Data("data".utf8).write(to:source)
        let backend = Backend(), controller = TelegramFileArchiveController(factory:{
            guard let repository = backend.repository else { throw S3ObjectStoreError.configuration }; return repository
        })
        for index in 1...8 {
            controller.accept(file:source,byteCount:4,identity:.init(service:"telegram",accountID:"11",conversationID:"37",messageID:"0:\(index)"),
                attachment:.init(id:"blocked-\(index)",kind:"file",name:"Synthetic.txt",size:4))
        }
        let spool = root.appendingPathComponent("queue")
        let repository = try ArchiveFileRepository(connectionString:database.connectionString,schema:database.schema,configuration:configuration,spoolDirectory:spool,keyProvider:{ _,_ in Data(repeating:0x59,count:32) })
        backend.repository = repository
        let identity = MessageArchiveIdentity(service:"telegram",accountID:"11",conversationID:"38",messageID:"0:1")
        let attachment = file("waiting"), media = TelegramMediaController(), provider = Provider()
        media.bind(provider:provider); media.retain(attachments:[attachment])
        media.reserveManualFile = { _ in controller.reserveManualCapture(identity:identity,attachment:.init(id:"waiting",kind:"file",name:"Synthetic.txt",size:4)) }
        media.start(attachment,purpose:.full); provider.events[0](.data(source,offset:0,size:4,complete:true))
        var deadline = ContinuousClock.now.advanced(by:.seconds(3))
        while controller.isBusy, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(media.transfers.first?.phase,.capturing)
        try await repository.setConversationFileSavingEnabled(identity:identity,enabled:false)
        deadline = ContinuousClock.now.advanced(by:.seconds(8))
        while media.transfers.first?.phase != .ready, ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(media.transfers.first?.phase,.ready)
        let records = try await repository.files(identity:identity,attachmentID:"waiting")
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath:spool.path)) ?? []).isEmpty)
    }
}
