import Foundation
import Postbox
import TelegramCore

public enum TelegramAdminEventKind: UInt32, CaseIterable, Sendable {
    case join = 1, leave = 2, invite = 4, ban = 8, unban = 16, kick = 32, unkick = 64
    case promote = 128, demote = 256, info = 512, settings = 1024, pinnedMessages = 2048
    case editMessages = 4096, deleteMessages = 8192, calls = 16384, invites = 32768, sendMessages = 65536, forums = 131072
}

public struct TelegramAdminHistoryFilter: Equatable, Sendable {
    public var kinds: Set<TelegramAdminEventKind>?
    public var adminIDs: Set<Int64>
    public init(kinds: Set<TelegramAdminEventKind>? = nil, adminIDs: Set<Int64> = []) {
        self.kinds = kinds; self.adminIDs = adminIDs
    }
    public static let all = Self()
    public var isValid: Bool {
        kinds?.isEmpty != true && adminIDs.count <= 100 && adminIDs.allSatisfy {
            telegramManagementPeerID($0)?.namespace == Namespaces.Peer.CloudUser
        }
    }
    var nativeFlags: Int32? { kinds.map { Int32($0.reduce(UInt32(0)) { $0 | $1.rawValue }) } }
}
