import Foundation
import MakoshCore
import Postbox
import TelegramCore
import SwiftSignalKit

public enum TelegramContactProfileState: Equatable, Sendable {
    case idle, loading, ready(TelegramContactProfile), unavailable(String)
}

// Define the transaction body outside MainActor: the legacy engine runs this
// ordinary escaping closure on its own Postbox queue, before main delivery.
func telegramContactProfilePeer(postbox: Postbox, peerID: Int64) -> Signal<Peer?, NoError> {
    postbox.transaction { transaction in transaction.getPeer(PeerId(peerID)) }
}

/// A source observation, scoped to the explicitly selected Telegram account.
public struct TelegramContactProfile: Equatable, Sendable {
    public let accountID: Int64
    public let peerID: Int64
    public let displayName: String
    public let username: String?
    public let phone: String?
    public enum Kind: Equatable, Sendable { case person, bot, group, supergroup, channel }
    public let kind: Kind
    public let about: String?
    public let memberCount: Int?
    public let isScam: Bool
    public let isFake: Bool
    public var isBot: Bool { kind == .bot }
    public var isPerson: Bool { kind == .person }
    public let observedAt: Date

    public init(accountID: Int64, peerID: Int64, displayName: String, username: String?,
                phone: String?, isBot: Bool, observedAt: Date) {
        self.init(accountID: accountID, peerID: peerID, displayName: displayName, username: username,
            phone: phone, kind: isBot ? .bot : .person, observedAt: observedAt)
    }

    public init(accountID: Int64, peerID: Int64, displayName: String, username: String?,
                phone: String?, kind: Kind, about: String? = nil, memberCount: Int? = nil,
                isScam: Bool = false, isFake: Bool = false, observedAt: Date) {
        self.accountID = accountID; self.peerID = peerID; self.displayName = displayName
        self.username = username; self.phone = phone; self.kind = kind
        self.about = about; self.memberCount = memberCount
        self.isScam = isScam; self.isFake = isFake; self.observedAt = observedAt
    }

    public var dossierIdentity: ServiceIdentity {
        ServiceIdentity(service: "telegram", accountID: String(accountID), externalID: String(peerID))
    }

    /// Usernames remain profile display data; the dossier schema has no username field.
    public var dossierImport: ImportedContact {
        ImportedContact(externalID: String(peerID), displayName: displayName,
            phones: phone.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
    }
}

public func telegramContactProfile(peer: Peer, accountID: Int64,
    observedAt: Date, cachedData: CachedPeerData? = nil) -> TelegramContactProfile? {
    let kind: TelegramContactProfile.Kind, name: String, username: String?, phone: String?
    let about: String?, count: Int?, scam: Bool, fake: Bool
    if let user = peer as? TelegramUser, user.id.namespace == Namespaces.Peer.CloudUser {
        kind = user.botInfo == nil ? .person : .bot
        name = [user.firstName, user.lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        username = user.username; phone = user.phone
        about = (cachedData as? CachedUserData)?.about; count = nil
        scam = user.flags.contains(.isScam); fake = user.flags.contains(.isFake)
    } else if let group = peer as? TelegramGroup, group.id.namespace == Namespaces.Peer.CloudGroup {
        kind = .group; name = group.title; username = nil; phone = nil
        about = (cachedData as? CachedGroupData)?.about
        count = group.participantCount >= 0 ? group.participantCount : nil
        scam = false; fake = false
    } else if let channel = peer as? TelegramChannel, channel.id.namespace == Namespaces.Peer.CloudChannel {
        switch channel.info { case .broadcast: kind = .channel; case .group: kind = .supergroup }
        name = channel.title; username = channel.username; phone = nil
        about = (cachedData as? CachedChannelData)?.about
        count = (cachedData as? CachedChannelData)?.participantsSummary.memberCount.flatMap { $0 >= 0 ? Int($0) : nil }
        scam = channel.flags.contains(.isScam); fake = channel.flags.contains(.isFake)
    } else { return nil }
    return TelegramContactProfile(accountID: accountID, peerID: peer.id.toInt64(), displayName: name,
        username: username, phone: phone, kind: kind, about: scam || fake ? nil : about,
        memberCount: count, isScam: scam, isFake: fake, observedAt: observedAt)
}
