import Foundation
import MakoshCore
import MakoshPersons
import MakoshTelegram

/// `MakoshPersons` sees Telegram only through this bridge: profiles become cards, the
/// account is checked on every call, and engine errors become section failures.
struct TelegramContactsBridgeAdapter: TelegramContactsBridge {
    let provider: @MainActor @Sendable () -> (any TelegramContactsProvider)?

    init(provider: @escaping @MainActor @Sendable () -> (any TelegramContactsProvider)?) { self.provider = provider }

    private func current(_ accountID: String) async throws -> any TelegramContactsProvider {
        guard let provider = await provider(), String(provider.accountID) == accountID else { throw PersonsFailure.unreachable }
        return provider
    }

    static func card(_ profile: TelegramContactProfile) -> RemoteCard {
        RemoteCard(
            externalID: String(profile.peerID), etag: nil, makoshID: nil, imported: profile.dossierImport, kind: .person)
    }

    func contacts(accountID: String) async throws -> [RemoteCard] {
        let provider = try await current(accountID)
        do { return try await provider.contacts().filter(\.isPerson).map(Self.card) } catch { throw Self.failure(error) }
    }

    func addContact(accountID: String, peerID: String?, phone: String?, givenName: String, familyName: String) async throws -> String {
        let provider = try await current(accountID)
        do {
            let peer = try await provider.addContact(
                peerID: peerID.flatMap(Int64.init), phone: phone, firstName: givenName, lastName: familyName)
            return String(peer)
        } catch { throw Self.failure(error) }
    }

    func deleteContact(accountID: String, peerID: String) async throws {
        let provider = try await current(accountID)
        guard let peer = Int64(peerID) else { throw PersonsFailure.invalidInput("peer") }
        do { try await provider.deleteContact(peerID: peer) } catch { throw Self.failure(error) }
    }

    static func failure(_ error: Error) -> PersonsFailure {
        switch error as? TelegramContactsError {
        case .notFound?: .notInTelegram
        case .notReady?: .unreachable
        default: .unknownOutcome(stage: "telegram")
        }
    }
}
