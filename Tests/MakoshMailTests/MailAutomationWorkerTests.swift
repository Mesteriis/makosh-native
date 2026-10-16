import XCTest
import MakoshCore
@testable import MakoshMail

final class MailAutomationWorkerTests: XCTestCase {
    private func configuration() throws -> ContactWorkspaceConfiguration {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("PostgreSQL required") }
        return .init(connectionString: dsn, schema: "qa_mail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    }
    func testDisconnectClosesCommandAndNonInboxIdleConnections() async throws {
        let fixture = try await Fixture(mode: "imap", scenario: "monitor-starttls"); defer { fixture.close() }
        let config = try configuration()
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x4d, count: 32) })
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "localhost", imapPort: fixture.config.imapPort, imapSecurity: .startTLS, imapUsername: "qa", smtpHost: "localhost", smtpUsername: "qa")
        let worker = MailAccountWorker(account: account, repository: repository, configuration: config, storageFile: nil, spool: fixture.root.appendingPathComponent("spool"), credentials: .init(save: { _,_,_ in }, read: { _,_ in "synthetic" }), keyProvider: { _,_ in Data(repeating: 0x4d, count: 32) }, tlsCAFile: fixture.root.appendingPathComponent("cert.pem").path)
        let folders = try await worker.connect(), folder = try XCTUnwrap(folders.first { $0.path == "Other" })
        let stream = await worker.updates(folder: folder)
        let watcher = Task { for await _ in stream {} }
        defer { watcher.cancel() }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("idle-started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("idle-started").path))
        let before = try await fixture.count("active"); XCTAssertEqual(before, 2)
        await worker.disconnect()
        for _ in 0..<100 { if try await fixture.count("active") == 0 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let after = try await fixture.count("active"); XCTAssertEqual(after, 0)
    }
    func testDueScheduleSendsOnceOverActualSMTPAndRetainsSentCopy() async throws {
        let imap = try await Fixture(mode: "imap", scenario: "starttls"), smtp = try await Fixture(mode: "smtp", scenario: "starttls")
        defer { imap.close(); smtp.close() }
        let ca = imap.root.appendingPathComponent("both.pem")
        try (Data(contentsOf: imap.root.appendingPathComponent("cert.pem")) + Data(contentsOf: smtp.root.appendingPathComponent("cert.pem"))).write(to: ca)
        let config = try configuration()
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x49, count: 32) })
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "localhost", imapPort: imap.config.imapPort, imapSecurity: .startTLS, imapUsername: "qa", smtpHost: "localhost", smtpPort: smtp.config.smtpPort, smtpSecurity: .startTLS, smtpUsername: "qa")
        let worker = MailAccountWorker(account: account, repository: repository, configuration: config, storageFile: nil, spool: imap.root.appendingPathComponent("spool"), credentials: .init(save: { _,_,_ in }, read: { _,_ in "synthetic" }), keyProvider: { _,_ in Data(repeating: 0x49, count: 32) }, tlsCAFile: ca.path)
        _ = try await worker.connect()
        let draft = MailDraft(accountID: account.id, to: "peer@example.invalid", body: "Scheduled wire message")
        let due = Date(); _ = try await repository.schedule(draft, at: due, now: due.addingTimeInterval(-1))
        do { try await worker.runAutomation(now: due) }
        catch {
            let commands = try await smtp.count("commands"), data = try await smtp.count("data")
            XCTFail("Synthetic SMTP boundary: commands=\(commands), DATA=\(data), failure=\(error)")
            throw error
        }
        try await worker.runAutomation(now: due.addingTimeInterval(20))
        let snapshot = try await repository.snapshot()
        XCTAssertEqual(snapshot.submissions.count, 1); XCTAssertEqual(snapshot.submissions.first?.state, .accepted)
        XCTAssertTrue(snapshot.submissions.first?.sentCopySaved == true)
        XCTAssertEqual(snapshot.automation?.scheduled?.first?.state, .completed)
        await worker.disconnect()
        let data = try await smtp.count("data"); XCTAssertEqual(data, 1)
    }
    func testRuleRetainsFullBodyAndIssuesExactlyOneMove() async throws {
        let fixture = try await Fixture(mode: "imap", scenario: "rule-starttls"); defer { fixture.close() }
        let config = try configuration()
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x4a, count: 32) })
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "localhost", imapPort: fixture.config.imapPort, imapSecurity: .startTLS, imapUsername: "qa", smtpHost: "localhost", smtpUsername: "qa")
        let worker = MailAccountWorker(account: account, repository: repository, configuration: config, storageFile: nil, spool: fixture.root.appendingPathComponent("spool"), credentials: .init(save: { _,_,_ in }, read: { _,_ in "synthetic" }), keyProvider: { _,_ in Data(repeating: 0x4a, count: 32) }, tlsCAFile: fixture.root.appendingPathComponent("cert.pem").path)
        let folders = try await worker.connect(), folder = try XCTUnwrap(folders.first { $0.kind == .inbox })
        try await repository.saveIncomingRule(.init(accountID: account.id, field: .subject, value: "Fixture", action: .trash))
        try await repository.savePage([], folder: folder, uidValidity: 97, notifyIncoming: true)
        let letters = try await worker.page(folder: folder)
        try await worker.runAutomation(); try await worker.runAutomation()
        let stored = try await repository.letter(XCTUnwrap(letters.first).id)
        XCTAssertEqual(stored?.text, "Mail fixture body")
        XCTAssertTrue(stored?.removedFromSource == true)
        let state = try await repository.snapshot().automation?.ruleOperations.first?.state
        XCTAssertEqual(state, .completed)
        await worker.disconnect()
        let moves = try await fixture.count("move"); XCTAssertEqual(moves, 1)
    }
    func testAllFiftyOneNewArrivalsReachRulesIncludingOldestNewMessage() async throws {
        let fixture = try await Fixture(mode: "imap", scenario: "backlog-starttls"); defer { fixture.close() }
        let config = try configuration()
        let repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x4b, count: 32) })
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "localhost", imapPort: fixture.config.imapPort, imapSecurity: .startTLS, imapUsername: "qa", smtpHost: "localhost", smtpUsername: "qa")
        let worker = MailAccountWorker(account: account, repository: repository, configuration: config, storageFile: nil, spool: fixture.root.appendingPathComponent("spool"), credentials: .init(save: { _,_,_ in }, read: { _,_ in "synthetic" }), keyProvider: { _,_ in Data(repeating: 0x4b, count: 32) }, tlsCAFile: fixture.root.appendingPathComponent("cert.pem").path)
        let folders = try await worker.connect(), folder = try XCTUnwrap(folders.first { $0.kind == .inbox })
        try await repository.saveIncomingRule(.init(accountID: account.id, field: .subject, value: "Fixture", action: .trash))
        try await repository.savePage([], folder: folder, uidValidity: 97, notifyIncoming: true)
        _ = try await worker.page(folder: folder)
        let snapshot = try await repository.snapshot(), operations = snapshot.automation?.ruleOperations ?? []
        XCTAssertEqual(operations.count, 51)
        XCTAssertTrue(operations.contains { $0.key.uid == 1 })
        XCTAssertEqual(snapshot.notifications?.checkpoints[folder.id]?.maximumUID, 51)
        await worker.disconnect()
    }
    func testOversizedRulePreparationDoesNotStarveDueScheduledSend() async throws {
        let imap = try await Fixture(mode: "imap", scenario: "rule-big-starttls"), smtp = try await Fixture(mode: "smtp", scenario: "starttls")
        defer { imap.close(); smtp.close() }
        let ca = imap.root.appendingPathComponent("both.pem")
        try (Data(contentsOf: imap.root.appendingPathComponent("cert.pem")) + Data(contentsOf: smtp.root.appendingPathComponent("cert.pem"))).write(to: ca)
        let config = try configuration(), repository = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x4c, count: 32) })
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "localhost", imapPort: imap.config.imapPort, imapSecurity: .startTLS, imapUsername: "qa", smtpHost: "localhost", smtpPort: smtp.config.smtpPort, smtpSecurity: .startTLS, smtpUsername: "qa")
        let worker = MailAccountWorker(account: account, repository: repository, configuration: config, storageFile: nil, spool: imap.root.appendingPathComponent("spool"), credentials: .init(save: { _,_,_ in }, read: { _,_ in "synthetic" }), keyProvider: { _,_ in Data(repeating: 0x4c, count: 32) }, tlsCAFile: ca.path)
        let folders = try await worker.connect(), folder = try XCTUnwrap(folders.first { $0.kind == .inbox })
        try await repository.saveIncomingRule(.init(accountID: account.id, field: .subject, value: "Fixture", action: .trash))
        try await repository.savePage([], folder: folder, uidValidity: 97, notifyIncoming: true)
        _ = try await worker.page(folder: folder)
        let due = Date(); _ = try await repository.schedule(.init(accountID: account.id, to: "peer@example.invalid", body: "Unrelated scheduled letter"), at: due, now: due.addingTimeInterval(-1))
        try await worker.runAutomation(now: due)
        let state = try await repository.snapshot()
        XCTAssertEqual(state.submissions.first?.state, .accepted)
        XCTAssertEqual(state.automation?.ruleOperations.first?.state.rawValue, "preparationFailed")
        await worker.disconnect()
        let count = try await smtp.count("data"); XCTAssertEqual(count, 1)
    }
}
