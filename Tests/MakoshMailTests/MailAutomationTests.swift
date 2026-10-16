import XCTest
import MakoshCore
@testable import MakoshMail

final class MailAutomationTests: XCTestCase {
    private func repository() throws -> (MailRepository, ContactWorkspaceConfiguration) {
        guard let dsn = ProcessInfo.processInfo.environment["MAKOSH_TEST_DATABASE_URL"] else { throw XCTSkip("PostgreSQL required") }
        let config = ContactWorkspaceConfiguration(connectionString: dsn, schema: "qa_mail_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        return (MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x45, count: 32) }), config)
    }
    func testSignaturesAndTemplatesSurviveReopenWithoutCrossAccountLoss() async throws {
        let (repo, config) = try repository()
        let other = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x45, count: 32) })
        async let a: Void = repo.setSignature(accountID: "a", text: "Regards A")
        async let b: Void = other.setSignature(accountID: "b", text: "Regards B")
        _ = try await (a,b)
        let template = MailReplyTemplate(name: "Thanks", body: "Thank you")
        try await repo.saveTemplate(template)
        let state = try await other.snapshot().automation
        XCTAssertEqual(state?.signatures["a"], "Regards A")
        XCTAssertEqual(state?.signatures["b"], "Regards B")
        XCTAssertEqual(state?.templates.first?.body, "Thank you")
    }
    func testRulesIgnoreBaselineAndTrashWinsWithoutDuplicateAdmission() async throws {
        let (repo, _) = try repository()
        let folder = MailFolder(accountID: "a", path: "INBOX", kind: .inbox)
        try await repo.saveIncomingRule(.init(accountID: "a", field: .subject, value: "invoice", action: .archive))
        try await repo.saveIncomingRule(.init(accountID: "a", field: .from, value: "TEAM", action: .trash))
        func letter(_ uid: UInt32, account: String = "a") -> MailLetter {
            .init(key: .init(accountID: account, folder: "INBOX", uidValidity: 42, uid: uid), subject: "Invoice", senderName: "Team", sender: "team@example.invalid", recipient: "qa@example.invalid", date: Date())
        }
        try await repo.savePage([letter(1)], folder: folder, uidValidity: 42, notifyIncoming: true)
        var state = try await repo.snapshot().automation
        XCTAssertTrue(state?.ruleOperations.isEmpty == true)
        try await repo.savePage([letter(1), letter(2)], folder: folder, uidValidity: 42, notifyIncoming: true)
        try await repo.savePage([letter(2)], folder: folder, uidValidity: 42, notifyIncoming: true)
        state = try await repo.snapshot().automation
        XCTAssertEqual(state?.ruleOperations.count, 1)
        XCTAssertEqual(state?.ruleOperations.first?.destination, .trash)
        XCTAssertEqual(state?.ruleOperations.first?.key.uid, 2)
        let unmatched = MailIncomingRule(accountID: "b", field: .subject, value: "invoice", action: .trash)
        XCTAssertFalse(unmatched.matches(letter(2)))
    }
    func testSignatureDoesNotDuplicateWhenReopeningAndTemplateKeepsRecipients() {
        var draft = MailDraft(accountID: "a", to: "peer@example.invalid", cc: "copy@example.invalid", body: "Hello")
        draft = MailComposition.insertingSignature("Regards", into: draft)
        draft = MailComposition.insertingSignature("Regards", into: draft)
        XCTAssertEqual(draft.body, "Hello\n\nRegards")
        let templated = MailComposition.applying(.init(name: "Answer", body: "Thanks"), to: draft)
        XCTAssertEqual(templated.body, "Thanks\n\nRegards")
        XCTAssertEqual(templated.to, "peer@example.invalid")
        XCTAssertEqual(templated.cc, "copy@example.invalid")
    }
    func testRuleClaimAcrossConnectionsNeverReplaysUncertainMove() async throws {
        let (repo, config) = try repository()
        let other = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x45, count: 32) })
        let folder = MailFolder(accountID: "a", path: "INBOX", kind: .inbox)
        try await repo.saveIncomingRule(.init(accountID: "a", field: .subject, value: "Invoice", action: .trash))
        try await repo.savePage([], folder: folder, uidValidity: 42, notifyIncoming: true)
        let letter = MailLetter(key: .init(accountID: "a", folder: "INBOX", uidValidity: 42, uid: 2), subject: "Invoice", senderName: "QA", sender: "qa@example.invalid", recipient: "peer@example.invalid", date: Date())
        try await repo.savePage([letter], folder: folder, uidValidity: 42, notifyIncoming: true)
        let initial = try await repo.snapshot()
        let operation = try XCTUnwrap(initial.automation?.ruleOperations.first)
        async let a = repo.claimRuleOperation(operation.id)
        async let b = other.claimRuleOperation(operation.id)
        let claims = try await [a,b]
        XCTAssertEqual(claims.compactMap { $0 }.count, 1)
        let replay = try await other.claimRuleOperation(operation.id)
        XCTAssertNil(replay)
    }
    func testScheduledDraftSurvivesRestartAndClaimsOnlyOnceWhenDue() async throws {
        let (repo, config) = try repository()
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "imap.example.invalid", imapUsername: "qa", smtpHost: "smtp.example.invalid", smtpUsername: "qa")
        try await repo.saveAccount(account)
        let due = Date(timeIntervalSince1970: 2000)
        let draft = MailDraft(accountID: account.id, to: "peer@example.invalid", bcc: "hidden@example.invalid", body: "Scheduled")
        let scheduled = try await repo.schedule(draft, at: due, now: due.addingTimeInterval(-1))
        let other = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x45, count: 32) })
        let early = try await other.claimScheduled(accountID: account.id, now: due.addingTimeInterval(-0.1))
        XCTAssertNil(early)
        async let a = repo.claimScheduled(accountID: account.id, now: due)
        async let b = other.claimScheduled(accountID: account.id, now: due)
        let claimed = try await [a,b].compactMap { $0 }
        XCTAssertEqual(claimed.count, 1)
        XCTAssertEqual(claimed.first?.draft.bcc, "hidden@example.invalid")
        XCTAssertEqual(claimed.first?.id, scheduled.id)
        let replay = try await other.claimScheduled(accountID: account.id, now: due.addingTimeInterval(100))
        XCTAssertNil(replay)
        let saved = try await other.snapshot().automation?.scheduled?.first
        XCTAssertEqual(saved?.state, .admitted)
    }
    func testCancelledScheduleKeepsEditableDraftAndNeverClaims() async throws {
        let (repo, _) = try repository()
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "imap.example.invalid", imapUsername: "qa", smtpHost: "smtp.example.invalid", smtpUsername: "qa")
        try await repo.saveAccount(account)
        let draft = MailDraft(accountID: account.id, to: "peer@example.invalid", body: "Keep")
        let schedule = try await repo.schedule(draft, at: Date(timeIntervalSince1970: 10), now: Date(timeIntervalSince1970: 1))
        try await repo.cancelSchedule(schedule.id)
        let claimed = try await repo.claimScheduled(accountID: account.id, now: Date(timeIntervalSince1970: 20))
        XCTAssertNil(claimed)
        let snapshot = try await repo.snapshot()
        XCTAssertEqual(snapshot.drafts.first?.body, "Keep")
    }
    func testLiveSMTPAdmissionCannotBeResolvedOrRetriedFromAnotherConnection() async throws {
        let (repo, config) = try repository()
        let other = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x45, count: 32) })
        let draft = MailDraft(accountID: "a", to: "peer@example.invalid")
        let submission = MailSubmission(draftID: draft.id, accountID: "a", state: .submitting)
        try await repo.admit(submission)
        do { try await other.resolveUnknown(submission.id, wasSent: false); XCTFail("A live sender still owns the SMTP attempt") } catch { XCTAssertEqual(error as? MailFailure, .busy) }
        do { try await other.admit(.init(draftID: draft.id, accountID: "a", state: .submitting)); XCTFail("Must not permit a concurrent retry") } catch { XCTAssertEqual(error as? MailFailure, .unknownSubmission) }
    }
    func testResolvedUnknownSubmissionRejectsLateAcceptance() async throws {
        let (repo, _) = try repository()
        var submission = MailSubmission(draftID: UUID(), accountID: "a", state: .submitting)
        try await repo.admit(submission); submission.state = .unknown; try await repo.updateSubmission(submission)
        try await repo.resolveUnknown(submission.id, wasSent: false)
        submission.state = .accepted
        do { try await repo.updateSubmission(submission); XCTFail("Late completion must not overwrite the explicit resolution") } catch { XCTAssertEqual(error as? MailFailure, .invalidInput) }
    }
    func testLiveScheduledClaimCannotBeResolvedUntilOwnerFinishes() async throws {
        let (repo, config) = try repository()
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "imap.example.invalid", imapUsername: "qa", smtpHost: "smtp.example.invalid", smtpUsername: "qa")
        try await repo.saveAccount(account)
        let due = Date(); let scheduled = try await repo.schedule(.init(accountID: account.id, to: "peer@example.invalid"), at: due, now: due.addingTimeInterval(-1))
        _ = try await repo.claimScheduled(accountID: account.id, now: due)
        let other = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x45, count: 32) })
        do { try await other.resolveSchedule(scheduled.id, wasSent: false); XCTFail("Active schedule still owns admission") } catch { XCTAssertEqual(error as? MailFailure, .busy) }
    }
    func testAccountSourceReplacementCannotReuseRetainedIdentity() async throws {
        let (repo, _) = try repository()
        let original = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "one.example.invalid", imapUsername: "qa", smtpHost: "smtp.example.invalid", smtpUsername: "qa")
        try await repo.saveAccount(original)
        var replacement = original; replacement.imapHost = "two.example.invalid"
        do { try await repo.saveAccount(replacement); XCTFail("Distinct source requires distinct identity even for equal UIDVALIDITY/UID") } catch { XCTAssertEqual(error as? MailFailure, .invalidInput) }
        let state = try await repo.snapshot(); XCTAssertEqual(state.accounts.first?.imapHost, "one.example.invalid")
    }
    func testOtherConnectionCannotManuallySendClaimedSchedule() async throws {
        let (repo, config) = try repository()
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "imap.example.invalid", imapUsername: "qa", smtpHost: "smtp.example.invalid", smtpUsername: "qa")
        try await repo.saveAccount(account)
        let due = Date(), draft = MailDraft(accountID: account.id, to: "peer@example.invalid")
        _ = try await repo.schedule(draft, at: due, now: due.addingTimeInterval(-1))
        _ = try await repo.claimScheduled(accountID: account.id, now: due)
        let other = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x45, count: 32) })
        do { try await other.admit(.init(draftID: draft.id, accountID: account.id, state: .submitting)); XCTFail("Only the admitted schedule owner can start SMTP") }
        catch { XCTAssertEqual(error as? MailFailure, .unknownSubmission) }
    }
    func testUnknownScheduleResolutionCannotReleaseLiveSMTP() async throws {
        let (repo, config) = try repository()
        let account = MailAccount(displayName: "QA", email: "qa@example.invalid", imapHost: "imap.example.invalid", imapUsername: "qa", smtpHost: "smtp.example.invalid", smtpUsername: "qa")
        try await repo.saveAccount(account)
        let due = Date(), draft = MailDraft(accountID: account.id, to: "peer@example.invalid")
        let item = try await repo.schedule(draft, at: due, now: due.addingTimeInterval(-1))
        _ = try await repo.claimScheduled(accountID: account.id, now: due)
        let submission = MailSubmission(draftID: draft.id, accountID: account.id, state: .submitting)
        try await repo.admit(submission)
        try await repo.finishSchedule(item.id, state: .unknown)
        let other = MailRepository(configuration: config, keyProvider: { _,_ in Data(repeating: 0x45, count: 32) })
        do { try await other.resolveSchedule(item.id, wasSent: false); XCTFail("Schedule resolution cannot settle a still-live SMTP attempt") }
        catch { XCTAssertEqual(error as? MailFailure, .busy) }
        let state = try await other.snapshot(); XCTAssertEqual(state.submissions.first?.state, .submitting)
    }

}
