import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

final class MailCollectionRuleTests: XCTestCase {
    private let me = MailParticipant(address: "me@mine.ru", name: "Я")
    private let a = MailParticipant(address: "A@sidorov.ru", name: "Иванов")
    private let b = MailParticipant(address: "b@sidorov.ru", name: "")
    private let c = MailParticipant(address: "c@other.ru", name: "Сидоров")
    private let when = Date(timeIntervalSince1970: 1_000)

    private func facts(
        folder: MailFolderRole, from: MailParticipant?, to: [MailParticipant] = [], cc: [MailParticipant] = [], bcc: [MailParticipant] = [],
        list: Bool = false, bulk: Bool = false, auto: Bool = false, spam: Bool = false
    ) -> MailLetterFacts {
        MailLetterFacts(
            accountID: "acc", folder: folder, from: from, to: to, cc: cc, bcc: bcc, ownAddresses: ["me@mine.ru"], hasListHeaders: list,
            precedenceBulk: bulk, autoSubmitted: auto, markedSpam: spam, observedAt: when)
    }

    func testIncomingLetterCollectsOnlySender() {
        let observations = MailCollectionRule.observations(facts(folder: .inbox, from: a, to: [me], cc: [b]))
        XCTAssertEqual(observations.count, 1)
        let observation = try! XCTUnwrap(observations.first)
        XCTAssertEqual(observation.source, ImportSource(service: "mail", accountID: "acc"))
        XCTAssertEqual(observation.person.externalID, "a@sidorov.ru")
        XCTAssertEqual(observation.person.displayName, "Иванов")
        XCTAssertEqual(observation.person.emails, ["A@sidorov.ru"])
        XCTAssertEqual(observation.observedAt, when)
        XCTAssertEqual(observation.evidence, .mail(MailEvidence(accountID: "acc", address: "a@sidorov.ru", spam: false)))
    }

    func testSentLetterCollectsRecipientsWithoutSelf() {
        let observations = MailCollectionRule.observations(facts(folder: .sent, from: me, to: [a, me], cc: [b], bcc: [c]))
        XCTAssertEqual(observations.map(\.person.externalID), ["a@sidorov.ru", "b@sidorov.ru", "c@other.ru"])
        XCTAssertEqual(observations[1].person.displayName, "b@sidorov.ru", "a participant without a name is shown by address")
    }

    func testListHeadersBlockCollection() {
        XCTAssertTrue(MailCollectionRule.observations(facts(folder: .inbox, from: a, cc: [b], list: true)).isEmpty)
        XCTAssertTrue(MailCollectionRule.observations(facts(folder: .inbox, from: a, bulk: true)).isEmpty)
        XCTAssertTrue(MailCollectionRule.observations(facts(folder: .inbox, from: a, auto: true)).isEmpty)
    }

    func testRobotsAreSkipped() {
        XCTAssertTrue(MailCollectionRule.isRobot("noreply@shop.ru"))
        XCTAssertTrue(MailCollectionRule.isRobot("No-Reply@shop.ru"))
        XCTAssertTrue(MailCollectionRule.isRobot("mailer-daemon@x"))
        XCTAssertTrue(MailCollectionRule.isRobot("notifications@github.com"))
        XCTAssertFalse(MailCollectionRule.isRobot("ivan@x"))
        let robot = MailParticipant(address: "noreply@shop.ru", name: "Магазин")
        XCTAssertTrue(MailCollectionRule.observations(facts(folder: .inbox, from: robot)).isEmpty)
    }

    func testOwnAddressAndEmptySenderAreNotCollected() {
        XCTAssertTrue(MailCollectionRule.observations(facts(folder: .inbox, from: me)).isEmpty)
        XCTAssertTrue(MailCollectionRule.observations(facts(folder: .inbox, from: nil)).isEmpty)
        XCTAssertTrue(
            MailCollectionRule.observations(facts(folder: .other, from: MailParticipant(address: "not-an-address", name: ""))).isEmpty)
    }

    func testSpamGivesEvidenceNotObservations() {
        let junk = facts(folder: .junk, from: a, to: [me])
        XCTAssertTrue(MailCollectionRule.observations(junk).isEmpty)
        XCTAssertEqual(MailCollectionRule.spamEvidence(junk), [MailEvidence(accountID: "acc", address: "a@sidorov.ru", spam: true)])
        let marked = facts(folder: .inbox, from: a, spam: true)
        XCTAssertTrue(MailCollectionRule.observations(marked).isEmpty)
        XCTAssertEqual(MailCollectionRule.spamEvidence(marked).count, 1)
        XCTAssertTrue(MailCollectionRule.observations(facts(folder: .trash, from: a)).isEmpty)
        XCTAssertTrue(MailCollectionRule.spamEvidence(facts(folder: .trash, from: a)).isEmpty, "trash is not spam")
        XCTAssertTrue(MailCollectionRule.spamEvidence(facts(folder: .inbox, from: a)).isEmpty)
    }
}
