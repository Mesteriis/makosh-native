import Foundation
import MakoshCore
import XCTest

@testable import MakoshPersons

/// A Telegram account in memory: contacts by peer, phones Telegram knows.
actor FakeTelegramBridge: TelegramContactsBridge {
    var contacts: [String: RemoteCard] = [:]
    var knownPhones: [String: String] = ["79160000000": "4242"]
    private(set) var calls: [String] = []
    private var counter = 100

    func contacts(accountID: String) async throws -> [RemoteCard] {
        calls.append("contacts " + accountID)
        return contacts.values.sorted { $0.externalID < $1.externalID }
    }

    func addContact(accountID: String, peerID: String?, phone: String?, givenName: String, familyName: String) async throws -> String {
        calls.append("add \(peerID ?? "-") \(phone ?? "-") \(givenName) \(familyName)")
        let peer: String
        if let peerID {
            peer = peerID
        } else if let phone, let known = knownPhones[phone.filter(\.isNumber)] {
            peer = known
        } else {
            throw PersonsFailure.notInTelegram
        }
        contacts[peer] = RemoteCard(
            externalID: peer, etag: nil, makoshID: nil,
            imported: ImportedPerson(
                externalID: peer, displayName: [givenName, familyName].filter { !$0.isEmpty }.joined(separator: " "),
                phones: phone.map { [$0] } ?? []),
            kind: .person)
        return peer
    }

    func deleteContact(accountID: String, peerID: String) async throws {
        calls.append("delete " + peerID)
        guard contacts.removeValue(forKey: peerID) != nil else { throw PersonsFailure.notFound }
    }
}

final class TelegramBookAdapterTests: XCTestCase {
    private let id = UUID()

    private func card(phones: [String], givenName: String = "Пётр", familyName: String = "Иванов") -> PersonCard {
        PersonCard(
            makoshID: id, kind: .person, displayName: "Иванов Пётр", givenName: givenName, familyName: familyName, middleName: "",
            phones: phones,
            emails: [], organization: "", jobTitle: "")
    }

    func testTelegramCreateUsesPeerWhenKnownElsePhone() async throws {
        let bridge = FakeTelegramBridge()
        let adapter = TelegramBookAdapter(accountID: "100", bridge: bridge)
        let byPeer = try await adapter.create(card(phones: []), hint: "777")
        XCTAssertEqual(byPeer.externalID, "777")
        let byPhone = try await adapter.create(card(phones: ["+7 916 000-00-00"]), hint: nil)
        XCTAssertEqual(byPhone.externalID, "4242")
        let calls = await bridge.calls
        XCTAssertEqual(calls, ["add 777 - Пётр Иванов", "add - +7 916 000-00-00 Пётр Иванов"])
        let capabilities = await adapter.capabilities
        XCTAssertTrue(capabilities.requiresPhoneOrPeer)
        XCTAssertFalse(capabilities.acceptsOrganizations)
        XCTAssertFalse(capabilities.supportsMarker)
    }

    func testTelegramCreateWithoutPeerOrPhoneIsBlocked() async {
        let adapter = TelegramBookAdapter(accountID: "100", bridge: FakeTelegramBridge())
        do {
            _ = try await adapter.create(card(phones: []))
            XCTFail()
        } catch { XCTAssertEqual(error as? PersonsFailure, .noPhoneOrPeer) }
    }

    func testTelegramNilPeerIsNotInTelegram() async {
        let adapter = TelegramBookAdapter(accountID: "100", bridge: FakeTelegramBridge())
        do {
            _ = try await adapter.create(card(phones: ["+7 999 000-00-00"]))
            XCTFail()
        } catch { XCTAssertEqual(error as? PersonsFailure, .notInTelegram) }
    }

    func testTelegramChangesAreAlwaysFullAndUpdateRenames() async throws {
        let bridge = FakeTelegramBridge()
        let adapter = TelegramBookAdapter(accountID: "100", bridge: bridge)
        _ = try await adapter.create(card(phones: ["+7 916 000-00-00"]))
        let changes = try await adapter.changes(cursor: Data("anything".utf8))
        XCTAssertTrue(changes.full)
        XCTAssertNil(changes.cursor)
        XCTAssertEqual(changes.cards.map(\.externalID), ["4242"])
        let renamed = try await adapter.update(externalID: "4242", etag: nil, card: card(phones: ["+7 916 000-00-00"], givenName: "Петя"))
        XCTAssertEqual(renamed.externalID, "4242")
        let after = try await adapter.changes(cursor: nil)
        XCTAssertEqual(after.cards.first?.imported.displayName, "Петя Иванов")
        try await adapter.delete(externalID: "4242", etag: nil)
        let empty = try await adapter.changes(cursor: nil)
        XCTAssertTrue(empty.cards.isEmpty)
        let missing = try await adapter.find(makoshID: id)
        XCTAssertNil(missing, "Telegram carries no mark")
    }
}
