import Foundation
import CoreVideo
import Postbox
import TelegramCore

public struct TelegramCallPeer: Equatable, Sendable {
    public let accountID: Int64, peerID: Int64
    public let title: String
    public let canVoice: Bool, canVideo: Bool
    public let revision: String
    var isValid: Bool {
        telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser
            && telegramManagementPeerID(peerID)?.namespace == Namespaces.Peer.CloudUser && peerID != accountID
            && !title.isEmpty && title.utf16.count <= 512 && !title.contains("\0")
            && revision.utf8.count == 64 && revision.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
public struct TelegramIncomingCall: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let accountID: Int64, peerID: Int64
    public let title: String
    public let isVideo: Bool
    var isValid: Bool {
        telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser
            && telegramManagementPeerID(peerID)?.namespace == Namespaces.Peer.CloudUser && peerID != accountID
            && !title.isEmpty && title.utf16.count <= 512 && !title.contains("\0")
    }
}
public struct TelegramCallSnapshot: Identifiable, Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case authorizing, validating, requesting, connecting, connected, reconnecting, ending, ended, failed }
    public let id: UUID
    public let accountID: Int64, peerID: Int64
    public let title: String
    public let outgoing: Bool
    public var phase: Phase
    public var muted = false
    public var videoEnabled = false
    public var canVideo = false
    public var ringing = false
    public var connectedAt: Date?
    public var fingerprint: Data?
    public var explanation: String?
    public var isActive: Bool { ![.ended, .failed].contains(phase) }
}
enum TelegramCallError: Error { case unavailable, changed, failed, unsupported, permissionDenied, busy }
enum TelegramCallEvent {
    case committing
    case requesting(ringing: Bool)
    case connecting(fingerprint: Data)
    case transportConnected, transportReconnecting
    case remoteVideo(Bool)
    case videoFrame(CVPixelBuffer)
    case localVideoFrame(CVPixelBuffer), videoAvailability(Bool)
    case ended(String), failed(TelegramCallError)
}
@MainActor protocol TelegramCallPermissions: AnyObject {
    func authorize(video: Bool) async -> Bool
    func isAuthorized(video: Bool) -> Bool
}
@MainActor protocol TelegramCallRequest: AnyObject { func cancel() }
@MainActor protocol TelegramCallLease: AnyObject {
    /// Completion confirms local media release; it does not claim remote rollback.
    func stop(completed: @escaping @MainActor () -> Void)
    func setMuted(_ value: Bool) -> Bool
    func setVideo(_ value: Bool) async -> Bool
}
@MainActor protocol TelegramCallProvider: AnyObject {
    var accountID: Int64 { get }
    func loadPeer(_ id: Int64, receive: @escaping @MainActor (Result<TelegramCallPeer, TelegramCallError>) -> Void) -> any TelegramCallRequest
    func observeIncoming(receive: @escaping @MainActor (Result<[TelegramIncomingCall], TelegramCallError>) -> Void) -> any TelegramCallRequest
    func startOutgoing(basis: TelegramCallPeer, video: Bool, callID: UUID, receive: @escaping @MainActor (TelegramCallEvent) -> Bool) -> any TelegramCallLease
    func accept(incoming: TelegramIncomingCall, video: Bool, receive: @escaping @MainActor (TelegramCallEvent) -> Bool) -> any TelegramCallLease
    func decline(incoming: TelegramIncomingCall)
}

func telegramCallTarget(accountID: Int64?, chatID: Int64?, secret: TelegramSecretConversation?) -> Int64? {
    guard let accountID, telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser,
          let chatID else { return nil }
    let target: Int64
    if telegramManagementPeerID(chatID)?.namespace == Namespaces.Peer.CloudUser { target = chatID }
    else if telegramSecretPeerID(chatID) != nil, let secret, secret.state == .active { target = secret.regularPeerID }
    else { return nil }
    guard target != accountID, telegramManagementPeerID(target)?.namespace == Namespaces.Peer.CloudUser else { return nil }
    return target
}
