import Foundation
import MakoshCore
import MakoshMail
import MakoshPersons
import MakoshTelegram
import XCTest

@testable import MakoshApp

@MainActor
final class PersonSourceTests: XCTestCase {
    private let account = MailAccount(
        id: "acc", displayName: "QA", email: "Me@Mine.ru", imapHost: "imap.x", imapUsername: "me", smtpHost: "smtp.x", smtpUsername: "me")
    private let folders = [
        MailFolder(accountID: "acc", path: "INBOX", kind: .inbox), MailFolder(accountID: "acc", path: "Sent", kind: .sent),
        MailFolder(accountID: "acc", path: "Spam", kind: .junk),
    ]
    private func letter(folder: String, sender: String, name: String = "", to: String = "me@mine.ru", cc: String? = nil) -> MailLetter {
        var letter = MailLetter(
            key: .init(accountID: "acc", folder: folder, uidValidity: 1, uid: 7), subject: "s", senderName: name, sender: sender,
            recipient: to,
            date: Date(timeIntervalSince1970: 1_000))
        letter.cc = cc
        return letter
    }

    func testJunkFolderLetterGivesSpamEvidenceOnly() throws {
        let facts = try XCTUnwrap(
            MailPersonSource.facts(letter(folder: "Spam", sender: "spam@evil.test"), folders: folders, account: account))
        XCTAssertEqual(facts.folder, .junk)
        XCTAssertTrue(facts.markedSpam)
        XCTAssertTrue(MailCollectionRule.observations(facts).isEmpty)
        XCTAssertEqual(MailCollectionRule.spamEvidence(facts), [MailEvidence(accountID: "acc", address: "spam@evil.test", spam: true)])
    }

    func testIncomingSenderIsCollectedWithNameAndOwnAddressIsNot() throws {
        let facts = try XCTUnwrap(
            MailPersonSource.facts(
                letter(folder: "INBOX", sender: "Ivan@Sidorov.ru", name: "Иванов", cc: "b@x.ru"), folders: folders, account: account))
        XCTAssertEqual(facts.folder, .inbox)
        XCTAssertEqual(facts.ownAddresses, ["me@mine.ru"])
        XCTAssertEqual(facts.cc.map(\.address), ["b@x.ru"])
        XCTAssertFalse(facts.hasListHeaders)
        let observations = MailCollectionRule.observations(facts)
        XCTAssertEqual(observations.map(\.person.externalID), ["ivan@sidorov.ru"])
        XCTAssertEqual(observations.first?.person.displayName, "Иванов")
        XCTAssertEqual(observations.first?.observedAt, Date(timeIntervalSince1970: 1_000))
        let own = try XCTUnwrap(MailPersonSource.facts(letter(folder: "INBOX", sender: "me@mine.ru"), folders: folders, account: account))
        XCTAssertTrue(MailCollectionRule.observations(own).isEmpty)
    }

    func testSentLetterCollectsRecipientsAndBulkFlagsPassThrough() throws {
        var sent = letter(folder: "Sent", sender: "me@mine.ru", to: "a@x.ru, Me@mine.ru", cc: "c@x.ru")
        sent.listHeaders = true
        let facts = try XCTUnwrap(MailPersonSource.facts(sent, folders: folders, account: account))
        XCTAssertEqual(facts.folder, .sent)
        XCTAssertTrue(facts.hasListHeaders)
        XCTAssertEqual(facts.to.map(\.address), ["a@x.ru", "Me@mine.ru"])
        var plain = sent
        plain.listHeaders = nil
        let observations = MailCollectionRule.observations(try XCTUnwrap(MailPersonSource.facts(plain, folders: folders, account: account)))
        XCTAssertEqual(observations.map(\.person.externalID), ["a@x.ru", "c@x.ru"])
    }

    func testUnknownFolderIsOther() throws {
        let facts = try XCTUnwrap(
            MailPersonSource.facts(letter(folder: "Archive/2026", sender: "a@x.ru"), folders: folders, account: account))
        XCTAssertEqual(facts.folder, .other)
    }

    func testTelegramSourceSkipsBotsGroupsAndWarnings() {
        let person = TelegramContactProfile(
            accountID: 100, peerID: 1, displayName: "Анна", username: "anna", phone: "+7 916 000-00-00", isBot: false, observedAt: Date())
        let bot = TelegramContactProfile(
            accountID: 100, peerID: 2, displayName: "Бот", username: "bot", phone: nil, isBot: true, observedAt: Date())
        let group = TelegramContactProfile(
            accountID: 100, peerID: 3, displayName: "Группа", username: nil, phone: nil, kind: .group, observedAt: Date())
        let scam = TelegramContactProfile(
            accountID: 100, peerID: 4, displayName: "Мошенник", username: nil, phone: nil, kind: .person, isScam: true, observedAt: Date())
        let observations = TelegramPersonSource.observations(profiles: [person, bot, group, scam], evidence: .conversation)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.source, ImportSource(service: "telegram", accountID: "100"))
        XCTAssertEqual(observations.first?.person.externalID, "1")
        XCTAssertEqual(observations.first?.person.usernames, ["anna"])
        XCTAssertEqual(observations.first?.person.phones, ["+7 916 000-00-00"])
        XCTAssertEqual(observations.first?.evidence, .conversation)
    }

    func testAlreadyCollectedLettersAreNotRepeated() {
        let host = PersonsHost(synthetic: [:])
        XCTAssertTrue(host.markLetterCollected("a"))
        XCTAssertFalse(host.markLetterCollected("a"))
        XCTAssertTrue(host.markLetterCollected("b"))
    }

    func testLettersAtOrBelowTheFolderCursorAreNotCollected() {
        var letter = letter(folder: "INBOX", sender: "a@x.ru")
        letter.cacheSequence = 5
        XCTAssertFalse(MailPersonSource.admits(letter, after: 10))
        XCTAssertFalse(MailPersonSource.admits(letter, after: 5))
        XCTAssertTrue(MailPersonSource.admits(letter, after: 4))
        XCTAssertTrue(MailPersonSource.admits(letter, after: nil))
        letter.cacheSequence = nil
        XCTAssertTrue(MailPersonSource.admits(letter, after: 10), "a letter without a cache number is judged by the in-memory set")
    }

    func testAlreadyCollectedTelegramPeersAreNotProfiledAgain() {
        let host = PersonsHost(synthetic: [:])
        XCTAssertEqual(host.newPeers(accountID: "100", peerIDs: [1, 2]), [1, 2])
        XCTAssertEqual(host.newPeers(accountID: "100", peerIDs: [2, 3]), [3])
        XCTAssertEqual(host.newPeers(accountID: "200", peerIDs: [1]), [1])
    }
}
