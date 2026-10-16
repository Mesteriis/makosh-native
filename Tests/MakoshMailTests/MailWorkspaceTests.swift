import XCTest
import AppKit
import MakoshCore
import MakoshMail
@testable import MakoshApp

@MainActor final class MailWorkspaceTests: XCTestCase {
    func testAccountSignatureSwitchKeepsFormattingAndPreservesManualSignatureEdits() {
        let original = NSMutableAttributedString(string: "Body\n\nAccount A", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
        let view = NSTextView(); view.textStorage?.setAttributedString(original)
        let controller = MailRichTextController(initial: original); controller.textView = view
        XCTAssertTrue(controller.replaceSignature(previous: "Account A", with: "Account B"))
        XCTAssertEqual(controller.currentString(), "Body\n\nAccount B")
        XCTAssertEqual(controller.currentAttributed().attribute(.font, at: 0, effectiveRange: nil) as? NSFont, NSFont.boldSystemFont(ofSize: 15))
        view.textStorage?.setAttributedString(NSAttributedString(string: "Body\n\nMy edited signature"))
        XCTAssertFalse(controller.replaceSignature(previous: "Account B", with: "Account A"))
        XCTAssertEqual(controller.currentString(), "Body\n\nMy edited signature")
    }
    func testUnchangedRemoteHTMLSurvivesSaveAndEditedTextExportsNewHTML() throws {
        let draft = MailDraft(accountID: UUID().uuidString, body: "Remote body", bodyHTML: "<p><strong>Remote body</strong></p>")
        let original = NSAttributedString(string: draft.body)
        let same = try MailComposeSheet.capture(draft: draft, originalEditor: original, current: original)
        XCTAssertEqual(same.bodyHTML, draft.bodyHTML); XCTAssertNil(same.bodyRTF)
        let edited = try MailComposeSheet.capture(draft: draft, originalEditor: original, current: NSAttributedString(string: "Changed"))
        XCTAssertNotEqual(edited.bodyHTML, draft.bodyHTML); XCTAssertNotNil(edited.bodyRTF)
    }
    func testArchiveReplyAndPolicyUseSelectedLetterAccountAndFolder() async throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("PostgreSQL required") }
        let config = ContactWorkspaceConfiguration(connectionString: dsn, schema: "qa_mail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x73, count: 32) })
        let a = MailAccount(displayName: "A", email: "a@example.invalid", imapHost: "imap.example.invalid", imapUsername: "a", smtpHost: "smtp.example.invalid", smtpUsername: "a")
        var b = a; b.id = UUID().uuidString; b.email = "b@example.invalid"
        let first = MailFolder(accountID: a.id, path: "INBOX", kind: .inbox, uidValidity: 1)
        let second = MailFolder(accountID: b.id, path: "Other", kind: .other, uidValidity: 2)
        try await repository.saveAccount(a); try await repository.saveAccount(b)
        try await repository.saveFolders([first], accountID: a.id); try await repository.saveFolders([second], accountID: b.id)
        let letter = MailLetter(key: .init(accountID: b.id, folder: second.path, uidValidity: 2, uid: 1), subject: "From B", senderName: "Peer", sender: "peer@example.invalid", recipient: b.email, date: Date(), text: "Body")
        try await repository.saveLetters([letter])
        let model = MailWorkspaceModel(synthetic: true); await model.load(configuration: config)
        model.selectedFolder = first; model.showArchive = true; model.selectedID = letter.id
        XCTAssertEqual(model.actionFolder?.id, second.id)
        model.compose(reply: true); XCTAssertEqual(model.composer?.accountID, b.id)
        XCTAssertEqual(model.composer?.sourceFolder, second.path)
        model.compose(forward: true); XCTAssertEqual(model.composer?.accountID, b.id)
        model.selectArchive(); XCTAssertNil(model.selected); XCTAssertNil(model.actionFolder)
    }
    func testOfflineFolderLoadsCacheOutsideGlobalSnapshot() async throws {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("PostgreSQL required") }
        let config = ContactWorkspaceConfiguration(connectionString: dsn, schema: "qa_mail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x73, count: 32) })
        let a = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "imap.example.invalid", imapUsername: "qa", smtpHost: "smtp.example.invalid", smtpUsername: "qa")
        let folder = MailFolder(accountID: a.id, path: "Old", kind: .other, uidValidity: 1)
        try await repository.saveAccount(a); try await repository.saveFolders([folder], accountID: a.id)
        let old = MailLetter(key: .init(accountID: a.id, folder: "Old", uidValidity: 1, uid: 1), subject: "Old", senderName: "QA", sender: a.email, recipient: a.email, date: Date(), text: "Offline")
        try await repository.saveLetters([old])
        try await repository.saveLetters((1...1001).map { MailLetter(key: .init(accountID: a.id, folder: "INBOX", uidValidity: 1, uid: UInt32($0)), subject: "New", senderName: "QA", sender: a.email, recipient: a.email, date: Date()) })
        let model = MailWorkspaceModel(synthetic: true); await model.load(configuration: config)
        model.selectFolder(folder); await model.loadCachedFolder(folder)
        XCTAssertEqual(model.displayed.map(\.id), [old.id])
    }
}
