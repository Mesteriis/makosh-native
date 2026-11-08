import Foundation
import MakoshCore
import MakoshPersons
import XCTest

@testable import MakoshApp
@testable import MakoshTelegram

@MainActor
final class TelegramContactsProviderTests: XCTestCase {
    func testSyntheticProviderRoundTrip() async throws {
        let provider = TelegramSyntheticContactsProvider(accountID: 100)
        let initial = try await provider.contacts()
        XCTAssertEqual(initial.count, 2, "the synthetic account starts with two contacts")
        XCTAssertTrue(initial.allSatisfy(\.isPerson))
        let peer = try await provider.addContact(peerID: nil, phone: "+7 916 000-00-00", firstName: "Пётр", lastName: "Иванов")
        let contacts = try await provider.contacts()
        XCTAssertEqual(contacts.count, 3)
        XCTAssertEqual(contacts.first { $0.peerID == peer }?.displayName, "Пётр Иванов")
        _ = try await provider.addContact(peerID: peer, phone: nil, firstName: "Петя", lastName: "Иванов")
        let renamed = try await provider.contacts()
        XCTAssertEqual(renamed.first { $0.peerID == peer }?.displayName, "Петя Иванов")
        do {
            _ = try await provider.addContact(peerID: nil, phone: "+7 000 000-00-00", firstName: "Нет", lastName: "")
            XCTFail("an unknown phone is not in Telegram")
        } catch { XCTAssertEqual(error as? TelegramContactsError, .notFound) }
        try await provider.deleteContact(peerID: peer)
        let after = try await provider.contacts()
        XCTAssertEqual(after.count, 2)
        let profiles = try await provider.profiles(peerIDs: [initial[0].peerID, 999_999])
        XCTAssertEqual(profiles.map(\.peerID), [initial[0].peerID], "unknown peers are skipped")
    }

    func testSyntheticModelExposesTheProvider() async throws {
        let model = TelegramModel.syntheticPreview()
        let provider = try XCTUnwrap(model.contactsProvider())
        let contacts = try await provider.contacts()
        XCTAssertFalse(contacts.isEmpty)
        XCTAssertTrue(model.contactsProvider() === provider, "one provider per model")
    }

    func testBridgeMapsProfilesToRemoteCards() async throws {
        let provider = TelegramSyntheticContactsProvider(accountID: 100)
        let bridge = TelegramContactsBridgeAdapter { provider }
        let cards = try await bridge.contacts(accountID: "100")
        XCTAssertEqual(cards.count, 2)
        let first = try XCTUnwrap(cards.first)
        XCTAssertEqual(first.externalID, String(first.imported.externalID))
        XCTAssertEqual(first.kind, .person)
        XCTAssertNil(first.makoshID)
        XCTAssertFalse(first.imported.phones.isEmpty)
        do {
            _ = try await bridge.contacts(accountID: "200")
            XCTFail("another account is unreachable through this provider")
        } catch { XCTAssertEqual(error as? PersonsFailure, .unreachable) }
    }

    func testAddWithoutPeerUsesPhoneAndNotFoundBecomesNotInTelegram() async throws {
        let provider = TelegramSyntheticContactsProvider(accountID: 100)
        let bridge = TelegramContactsBridgeAdapter { provider }
        let peer = try await bridge.addContact(
            accountID: "100", peerID: nil, phone: "+7 916 000-00-00", givenName: "Пётр", familyName: "Иванов")
        XCTAssertFalse(peer.isEmpty)
        do {
            _ = try await bridge.addContact(accountID: "100", peerID: nil, phone: "+7 000 000-00-00", givenName: "Нет", familyName: "")
            XCTFail()
        } catch { XCTAssertEqual(error as? PersonsFailure, .notInTelegram) }
        try await bridge.deleteContact(accountID: "100", peerID: peer)
        let cards = try await bridge.contacts(accountID: "100")
        XCTAssertEqual(cards.count, 2)
        let adapter = TelegramBookAdapter(accountID: "100", bridge: bridge)
        let changes = try await adapter.changes(cursor: nil)
        XCTAssertTrue(changes.full)
        XCTAssertEqual(changes.cards.count, 2)
    }
}
