#if DEBUG
import Foundation

/// An in-memory Telegram contact list for tests and the isolated QA bundle. Phones the
/// synthetic account "knows" map to peers; anything else is not in Telegram.
public final class TelegramSyntheticContactsProvider: TelegramContactsProvider, @unchecked Sendable {
    public let accountID: Int64
    private let lock = NSLock()
    private var contactsByPeer: [Int64: TelegramContactProfile] = [:]
    private var knownPhones: [String: Int64]
    private var nextPeer: Int64 = 90_000

    public init(accountID: Int64) {
        self.accountID = accountID
        let anna = TelegramContactProfile(
            accountID: accountID, peerID: 7001, displayName: "Анна Синтетическая", username: "anna_synthetic", phone: "10000000001",
            isBot: false,
            observedAt: Date())
        let boris = TelegramContactProfile(
            accountID: accountID, peerID: 7002, displayName: "Борис Синтетический", username: nil, phone: "10000000002", isBot: false,
            observedAt: Date())
        contactsByPeer = [anna.peerID: anna, boris.peerID: boris]
        knownPhones = ["79160000000": 7003, "10000000001": 7001, "10000000002": 7002]
    }

    public func contacts() async throws -> [TelegramContactProfile] {
        lock.withLock { contactsByPeer.values.sorted { $0.peerID < $1.peerID } }
    }

    public func profiles(peerIDs: [Int64]) async throws -> [TelegramContactProfile] {
        lock.withLock { peerIDs.compactMap { contactsByPeer[$0] } }
    }

    public func addContact(peerID: Int64?, phone: String?, firstName: String, lastName: String) async throws -> Int64 {
        try lock.withLock {
            let peer: Int64
            if let peerID {
                peer = peerID
            } else if let phone, let known = knownPhones[phone.filter(\.isNumber)] {
                peer = known
            } else {
                throw TelegramContactsError.notFound
            }
            contactsByPeer[peer] = TelegramContactProfile(
                accountID: accountID, peerID: peer, displayName: [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " "),
                username: contactsByPeer[peer]?.username, phone: phone ?? contactsByPeer[peer]?.phone, isBot: false, observedAt: Date())
            return peer
        }
    }

    public func deleteContact(peerID: Int64) async throws {
        lock.withLock { contactsByPeer[peerID] = nil }
    }
}
#endif
