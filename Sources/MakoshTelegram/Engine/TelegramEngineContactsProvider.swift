import Foundation
import Postbox
import SwiftSignalKit
import TelegramCore

public enum TelegramContactsError: Error, Equatable, Sendable {
    /// Telegram knows no account with this phone.
    case notFound
    case failed
    case notReady
}

/// The contacts of one Telegram account, as the Persons section needs them: the list,
/// profiles of known peers, adding by peer or phone, removing. All work runs on the engine's
/// queues; nothing here touches the main actor.
public protocol TelegramContactsProvider: AnyObject, Sendable {
    var accountID: Int64 { get }
    func contacts() async throws -> [TelegramContactProfile]
    /// Profiles of these peers, skipping peers the account does not know.
    func profiles(peerIDs: [Int64]) async throws -> [TelegramContactProfile]
    /// Adds (or renames) a contact by peer, else imports by phone; returns the peer id.
    func addContact(peerID: Int64?, phone: String?, firstName: String, lastName: String) async throws -> Int64
    func deleteContact(peerID: Int64) async throws
}

private final class TelegramAwaitBox: @unchecked Sendable {
    let disposable = MetaDisposable()
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

/// Waits for a signal's first value, or its completion when it emits none; any signal error
/// becomes `TelegramContactsError.failed` (the engine's error types are plain enums).
func telegramAwait<T: Sendable, E>(_ signal: Signal<T, E>) async throws -> T? {
    let box = TelegramAwaitBox()
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, Error>) in
        box.disposable.set(
            signal.start(
                next: { value in
                    if box.claim() { continuation.resume(returning: value) }
                    box.disposable.dispose()
                },
                error: { _ in if box.claim() { continuation.resume(throwing: TelegramContactsError.failed) } },
                completed: { if box.claim() { continuation.resume(returning: nil) } }))
    }
}

final class TelegramEngineContactsProvider: TelegramContactsProvider, @unchecked Sendable {
    private let account: Account
    let accountID: Int64

    init(account: Account) {
        self.account = account
        accountID = account.peerId.toInt64()
    }

    func contacts() async throws -> [TelegramContactProfile] {
        let ids: Signal<[Int64], NoError> = account.postbox.transaction { transaction in
            transaction.getContactPeerIds().map { $0.toInt64() }.sorted()
        }
        guard let peerIDs = try await telegramAwait(ids) else { throw TelegramContactsError.notReady }
        return try await profiles(peerIDs: peerIDs)
    }

    func profiles(peerIDs: [Int64]) async throws -> [TelegramContactProfile] {
        let accountID = accountID
        let signal: Signal<[TelegramContactProfile], NoError> = account.postbox.transaction { transaction in
            peerIDs.compactMap { id -> TelegramContactProfile? in
                guard let peer = transaction.getPeer(PeerId(id)) else { return nil }
                return telegramContactProfile(
                    peer: peer, accountID: accountID, observedAt: Date(), cachedData: transaction.getPeerCachedData(peerId: PeerId(id)))
            }
        }
        return try await telegramAwait(signal) ?? []
    }

    func addContact(peerID: Int64?, phone: String?, firstName: String, lastName: String) async throws -> Int64 {
        let engine = TelegramEngine(account: account)
        if let peerID {
            do {
                _ = try await telegramAwait(
                    engine.contacts.addContactInteractively(
                        peerId: PeerId(peerID), firstName: firstName, lastName: lastName, phoneNumber: phone ?? "",
                        addToPrivacyExceptions: false))
            } catch { throw TelegramContactsError.failed }
            return peerID
        }
        guard let phone, !phone.isEmpty else { throw TelegramContactsError.notFound }
        let imported: Signal<Int64?, NoError> =
            engine.contacts.importContact(firstName: firstName, lastName: lastName, phoneNumber: phone) |> map { $0?.toInt64() }
        guard let result = try await telegramAwait(imported), let peer = result else { throw TelegramContactsError.notFound }
        return peer
    }

    func deleteContact(peerID: Int64) async throws {
        _ = try await telegramAwait(TelegramEngine(account: account).contacts.deleteContactPeerInteractively(peerId: PeerId(peerID)))
    }
}
