import XCTest
import MakoshCore
@testable import MakoshMail
@testable import MakoshApp

final class MailNotificationRecoveryStoreTests: XCTestCase {
    func testRouteSurvivesRestartAndDestructiveAdmissionIsAtomic() async throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("PostgreSQL required") }
        let config = ContactWorkspaceConfiguration(connectionString: dsn, schema: "qa_mail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let first = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x48, count: 32) })
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "imap.example.invalid", imapUsername: "qa", smtpHost: "smtp.example.invalid", smtpUsername: "qa")
        let folder = MailFolder(accountID: account.id, path: "INBOX", kind: .inbox)
        try await first.saveAccount(account)
        try await first.savePage([], folder: folder, uidValidity: 42, notifyIncoming: true)
        let letter = MailLetter(key: .init(accountID: account.id, folder: "INBOX", uidValidity: 42, uid: 1), subject: "New", senderName: "QA", sender: "peer@example.invalid", recipient: account.email, date: Date(), text: "Retained")
        try await first.savePage([letter], folder: folder, uidValidity: 42, notifyIncoming: true)
        _ = try await first.takeNotificationBatch(accountIDs: [account.id])
        let reopened = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x48, count: 32) })
        let saved = try await reopened.snapshot().notifications?.routes?[letter.id]
        XCTAssertEqual(saved?.event.key, letter.key)
        async let a = first.claimNotificationAction(letter.id)
        async let b = reopened.claimNotificationAction(letter.id)
        let claims = try await [a,b]
        XCTAssertEqual(claims.filter { $0 }.count, 1)
        let replay = try await reopened.claimNotificationAction(letter.id); XCTAssertFalse(replay)
    }
}
@MainActor final class MailNotificationRecoveryPresentationTests: XCTestCase {
    func testColdActionWaitsForTrustedRestoredRouteAndDoesNotPresentOldBanner() {
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "imap.example.invalid", imapUsername: "qa", smtpHost: "smtp.example.invalid", smtpUsername: "qa")
        let letter = MailLetter(key: .init(accountID: account.id, folder: "INBOX", uidValidity: 42, uid: 1), subject: "Restored", senderName: "QA", sender: "peer@example.invalid", recipient: account.email, date: Date(), text: "Offline")
        var snapshot = MailSnapshot(); snapshot.accounts = [account]; snapshot.letters = [letter]; snapshot.folders = [.init(accountID: account.id, path: "INBOX", kind: .inbox, uidValidity: 42)]
        var settings = MailNotificationState(); settings.routes = [letter.id: .init(event: .init(letter: letter), rule: .init())]; snapshot.notifications = settings
        let registry = MailNotificationRegistry(), controller = MailNotificationController()
        registry.activate(identifier: letter.id, action: .open)
        var opened: [String] = []
        _ = registry.register(controller) { _,event in opened.append(event.id) }
        controller.update(snapshot: snapshot, connected: [])
        registry.restore(controller)
        XCTAssertEqual(opened, [letter.id])
        XCTAssertNil(controller.delivery)
        XCTAssertFalse(controller.canPresent(identifier: letter.id))
        registry.activate(identifier: letter.id, action: .trash)
        XCTAssertEqual(opened.count, 1)
        controller.setPresentationEnvironment(active: false, locked: true)
        XCTAssertFalse(controller.canActivate(identifier: letter.id))
    }
}
