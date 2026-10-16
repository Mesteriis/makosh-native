import XCTest
import MakoshCore
@testable import MakoshMail

final class MailNotificationStoreTests: XCTestCase {
    private func store() throws -> (MailRepository, ContactWorkspaceConfiguration) {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("PostgreSQL required") }
        let config = ContactWorkspaceConfiguration(connectionString: dsn, schema: "qa_mail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        return (MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x41, count: 32) }), config)
    }
    private func letter(_ uid: UInt32, account: String = "a", validity: UInt32 = 7, sender: String = "peer@example.invalid", seen: Bool = false) -> MailLetter {
        .init(key: .init(accountID: account, folder: "INBOX", uidValidity: validity, uid: uid), subject: "New", senderName: "Peer", sender: sender, recipient: "qa@example.invalid", date: Date(), seen: seen)
    }
    func testOnlyNewUnreadInboxEventsArePersistedAfterBaseline() async throws {
        let (repository, _) = try store(), folder = MailFolder(accountID: "a", path: "INBOX", kind: .inbox)
        try await repository.savePage([letter(10)], folder: folder, uidValidity: 7, notifyIncoming: true)
        let baseline = try await repository.snapshot(); XCTAssertTrue(baseline.notifications?.pending.isEmpty ?? true)
        try await repository.savePage([letter(10),letter(11),letter(12,seen:true)], folder: folder, uidValidity: 7, notifyIncoming: true)
        let next = try await repository.snapshot(); XCTAssertEqual(next.notifications?.pending.map(\.key.uid), [11])
    }
    func testReopenDoesNotReplayAndChangedValidityResetsBaseline() async throws {
        let (repository, config) = try store(), folder = MailFolder(accountID: "a", path: "INBOX", kind: .inbox)
        try await repository.savePage([letter(10)], folder: folder, uidValidity: 7, notifyIncoming: true)
        try await repository.savePage([letter(11)], folder: folder, uidValidity: 7, notifyIncoming: true)
        let events = try await repository.takeNotificationEvents(accountID: "a"); XCTAssertEqual(events.map(\.key.uid),[11])
        let reopened = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x41,count:32) })
        try await reopened.savePage([letter(11)], folder: folder, uidValidity: 7, notifyIncoming: true)
        let repeated = try await reopened.takeNotificationEvents(accountID: "a"); XCTAssertTrue(repeated.isEmpty)
        try await reopened.savePage([letter(11,validity:8)], folder: folder, uidValidity: 8, notifyIncoming: true)
        let reset = try await reopened.takeNotificationEvents(accountID: "a"); XCTAssertTrue(reset.isEmpty)
        try await reopened.savePage([letter(12,validity:8)], folder: folder, uidValidity: 8, notifyIncoming: true)
        let fresh = try await reopened.takeNotificationEvents(accountID: "a"); XCTAssertEqual(fresh.map(\.key.uid),[12])
    }
    func testMutedSenderAdvancesCursorWithoutAffectingAnotherSenderOrAccount() async throws {
        let (repository, _) = try store(), folder = MailFolder(accountID: "a", path: "INBOX", kind: .inbox)
        var prefs = MailNotificationPreferences()
        prefs.overrides[MailNotificationScope.sender(accountID: "a", address: "PEER@example.invalid").id] = .init(enabled:false)
        try await repository.updateNotificationPreferences(prefs)
        try await repository.savePage([letter(10)], folder: folder, uidValidity: 7, notifyIncoming: true)
        try await repository.savePage([letter(11),letter(12,sender:"other@example.invalid")], folder: folder, uidValidity: 7, notifyIncoming: true)
        let events = try await repository.takeNotificationEvents(accountID:"a"); XCTAssertEqual(events.map(\.key.uid),[12])
        prefs.overrides = [:]; try await repository.updateNotificationPreferences(prefs)
        try await repository.savePage([letter(11),letter(12,sender:"other@example.invalid")], folder: folder, uidValidity: 7, notifyIncoming: true)
        let old = try await repository.takeNotificationEvents(accountID:"a"); XCTAssertTrue(old.isEmpty)
        let other = MailFolder(accountID:"b",path:"INBOX",kind:.inbox)
        try await repository.savePage([letter(10,account:"b")],folder:other,uidValidity:7,notifyIncoming:true)
        try await repository.savePage([letter(11,account:"b")],folder:other,uidValidity:7,notifyIncoming:true)
        let separate = try await repository.takeNotificationEvents(accountID:"b"); XCTAssertEqual(separate.map(\.key.uid),[11])
    }
    func testHistoricalSearchAndOtherFoldersDoNotCreateEvents() async throws {
        let (repository, _) = try store(), folder = MailFolder(accountID:"a",path:"INBOX",kind:.inbox)
        try await repository.savePage([letter(1)],folder:folder,uidValidity:7,notifyIncoming:true)
        try await repository.savePage([letter(99)],folder:folder,uidValidity:7)
        let events = try await repository.takeNotificationEvents(accountID:"a"); XCTAssertTrue(events.isEmpty)
        var other = letter(100); other.key = .init(accountID:"a",folder:"Sent",uidValidity:7,uid:100)
        try await repository.savePage([other],folder:.init(accountID:"a",path:"Sent",kind:.sent),uidValidity:7,notifyIncoming:true)
        let sent = try await repository.takeNotificationEvents(accountID:"a"); XCTAssertTrue(sent.isEmpty)
    }
    func testTwoConsumersTakeAnEventOnce() async throws {
        let (repository, config) = try store(), folder = MailFolder(accountID:"a",path:"INBOX",kind:.inbox)
        try await repository.savePage([letter(1)],folder:folder,uidValidity:7,notifyIncoming:true)
        try await repository.savePage([letter(2)],folder:folder,uidValidity:7,notifyIncoming:true)
        let second = MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:0x41,count:32)})
        async let a = repository.takeNotificationEvents(accountID:"a")
        async let b = second.takeNotificationEvents(accountID:"a")
        let (one,two) = try await (a,b); XCTAssertEqual(one.count+two.count,1)
    }
    func testReadOrRemovedBeforeConsumptionCannotCreateACard() async throws {
        let (repository, _) = try store(), folder = MailFolder(accountID:"a",path:"INBOX",kind:.inbox)
        try await repository.savePage([letter(1)],folder:folder,uidValidity:7,notifyIncoming:true)
        try await repository.savePage([letter(2),letter(3)],folder:folder,uidValidity:7,notifyIncoming:true)
        var removed = letter(3); removed.removedFromSource = true
        try await repository.saveLetters([letter(2,seen:true),removed])
        let pending = try await repository.takeNotificationEvents(accountID:"a"); XCTAssertTrue(pending.isEmpty)
    }
    func testIndependentPreferenceEditsFromTwoConnectionsPreserveBothRules() async throws {
        let (repository, config) = try store()
        let second = MailRepository(configuration:config,keyProvider:{_,_ in Data(repeating:0x41,count:32)})
        let a = MailNotificationScope.sender(accountID:"a",address:"one@example.invalid")
        let b = MailNotificationScope.sender(accountID:"a",address:"two@example.invalid")
        async let first:Void = repository.setNotificationRule(scope:a,rule:.init(enabled:false))
        async let other:Void = second.setNotificationRule(scope:b,rule:.init(sound:false))
        _ = try await (first,other)
        let prefs = try await repository.snapshot().notifications?.preferences
        XCTAssertEqual(prefs?.overrides[a.id]?.enabled,false); XCTAssertEqual(prefs?.overrides[b.id]?.sound,false)
    }
    func testParentRestrictionsAndPreviewSoundAreAccountScoped() {
        var p = MailNotificationPreferences()
        p.overrides[MailNotificationScope.account("a").id] = .init(previews:false,sound:false)
        p.overrides[MailNotificationScope.folder(accountID:"a",path:"INBOX").id] = .init(enabled:false)
        XCTAssertFalse(p.effective(for:letter(1)).enabled)
        XCTAssertFalse(p.effective(for:letter(1)).previews)
        XCTAssertTrue(p.effective(for:letter(1,account:"b")).enabled)
        XCTAssertTrue(p.effective(for:letter(1,account:"b")).sound)
    }
    func testAtomicBatchIncludesEventHeaderOutsideTheGlobalSnapshotPage() async throws {
        let (repository,_) = try store(),folder=MailFolder(accountID:"a",path:"INBOX",kind:.inbox)
        try await repository.savePage([letter(1)],folder:folder,uidValidity:7,notifyIncoming:true)
        let earlier=try await repository.snapshot()
        try await repository.savePage([letter(2)],folder:folder,uidValidity:7,notifyIncoming:true)
        try await repository.saveLetters((1...1001).map { letter(UInt32($0),account:"other") })
        let batch=try await repository.takeNotificationBatch(accountIDs:["a"])
        XCTAssertFalse(earlier.letters.contains { $0.key.accountID=="a" && $0.key.uid==2 })
        XCTAssertEqual(batch.events.map(\.key.uid),[2])
        XCTAssertTrue(batch.snapshot.letters.contains { $0.id==batch.events.first?.id && !$0.seen })
        XCTAssertTrue(batch.snapshot.notifications?.pending.isEmpty == true)
    }
    func testNotificationBaselinePreservesReferenceFolderOrder() async throws {
        let (repository,_) = try store(),inbox=MailFolder(accountID:"a",path:"INBOX",kind:.inbox)
        let sent=MailFolder(accountID:"a",path:"Sent",kind:.sent)
        try await repository.saveFolders([inbox,sent],accountID:"a")
        try await repository.savePage([letter(1)],folder:inbox,uidValidity:7,notifyIncoming:true)
        let snapshot=try await repository.snapshot()
        XCTAssertEqual(snapshot.folders.map(\.id),[inbox.id,sent.id])
    }
}
