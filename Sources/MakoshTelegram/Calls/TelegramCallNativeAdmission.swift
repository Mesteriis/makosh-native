import Foundation
import CryptoKit
import TelegramCore
import TelegramApi
import Postbox
import Darwin

func telegramCallPeer(result: Api.users.UserFull, accountID: Int64, peerID: Int64) -> TelegramCallPeer? {
    guard telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser,
          let id = telegramManagementPeerID(peerID), id.namespace == Namespaces.Peer.CloudUser, accountID != peerID,
          let peer = makoshAvatarUserPhotoResult(result, accountPeerId: id, fallback: false)?.peer as? TelegramUser,
          !peer.isDeleted, peer.botInfo == nil, case let .personal(hash) = peer.accessHash, hash != 0 else { return nil }
    let full: Api.UserFull
    switch result { case let .userFull(value, _, _): full = value }
    let flags: Int32
    switch full {
    case let .userFull(value, _, number, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _):
        guard number == id.id._internalGetInt64Value() else { return nil }; flags = value
    }
    let encoder = PostboxEncoder(); peer.encode(encoder); encoder.encodeInt64(accountID, forKey: "account"); encoder.encodeInt32(flags, forKey: "callFlags")
    let allowed = flags & 1 == 0 && flags & (1 << 5) == 0 && flags & (1 << 4) != 0
    let value = TelegramCallPeer(accountID: accountID, peerID: peerID, title: telegramPeerTitle(peer), canVoice: allowed,
        canVideo: allowed && flags & (1 << 13) != 0, revision: SHA256.hash(data: encoder.makeData()).map { String(format: "%02x", $0) }.joined())
    return value.isValid ? value : nil
}
struct TelegramCallRelay: Equatable, Sendable {
    let host: String, port: UInt16, username: String, password: String
    let id: UInt8, turn: Bool, tcp: Bool
}
struct TelegramCallMediaConfiguration: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var audioDevices = TelegramCallAudioSelection()
    let version: String, key: Data, fingerprint: Data
    let outgoing: Bool, video: Bool, allowP2P: Bool
    let maxLayer: Int32
    let servers: [TelegramCallRelay]
    let proxy: TelegramProxyServer?
    var description: String { "TelegramCallMediaConfiguration(redacted)" }
    var debugDescription: String { description }
    init?(session: CallSession, internalID: UUID, outgoing: Bool, video: Bool, proxy: TelegramProxyServer?) {
        guard session.id == internalID, session.isOutgoing == outgoing, !video || session.isVideoPossible,
              case let .active(_, key, fingerprint, connections, maxLayer, version, _, allowsP2P, _) = session.state,
              key.count == 256, key.contains(where: { $0 != 0 }), fingerprint.count == 32,
              ["2.7.7", "5.0.0"].contains(version), (65...92).contains(maxLayer), connections.alternatives.count <= 31 else { return nil }
        if let proxy { guard proxy.isValid, case .socks5 = proxy.connection else { return nil } }
        var unique: [CallSessionConnection] = []
        for connection in [connections.primary] + connections.alternatives where !unique.contains(connection) { unique.append(connection) }
        let reflectors = unique.compactMap { connection -> CallSessionConnection.Reflector? in
            if case let .reflector(value) = connection { return value }; return nil
        }
        let ids = reflectors.map(\.id).sorted()
        guard Set(ids).count == ids.count, ids.count <= 32 else { return nil }
        var mapping: [Int64: UInt8] = [:]; for (offset, id) in ids.enumerated() { mapping[id] = UInt8(offset + 1) }
        var servers: [TelegramCallRelay] = []
        for connection in unique {
            let hosts: [(String, Int32)], username: String, password: String, tag: UInt8, turn: Bool, stun: Bool, tcp: Bool
            switch connection {
            case let .reflector(value):
                guard value.peerTag.count == 16, let number = mapping[value.id] else { return nil }
                hosts = [(value.ip, AF_INET), (value.ipv6, AF_INET6)]; username = "reflector"
                password = value.peerTag.map { String(format: "%02x", $0) }.joined(); tag = number; turn = true; stun = false; tcp = value.isTcp
            case let .webRtcReflector(value):
                hosts = [(value.ip, AF_INET), (value.ipv6, AF_INET6)]; username = value.username; password = value.password
                tag = 0; turn = value.hasTurn; stun = value.hasStun; tcp = false
            }
            let rawPort: Int32
            switch connection { case let .reflector(value): rawPort = value.port; case let .webRtcReflector(value): rawPort = value.port }
            guard let port = UInt16(exactly: rawPort), port != 0, turn || stun,
                  username.utf8.count <= 255, password.utf8.count <= 255, !username.contains("\0"), !password.contains("\0"),
                  !turn || (!username.isEmpty && !password.isEmpty) else { return nil }
            var found = false
            for (host, family) in hosts where !host.isEmpty {
                guard host.utf8.count <= 255, !host.contains("\0") else { return nil }
                var address = in6_addr()
                guard host.withCString({ inet_pton(family, $0, &address) }) == 1 else { return nil }
                found = true
                if turn { servers.append(.init(host: host, port: port, username: username, password: password, id: tag, turn: true, tcp: tcp)) }
                if stun && proxy == nil && allowsP2P { servers.append(.init(host: host, port: port, username: "", password: "", id: 0, turn: false, tcp: false)) }
            }
            guard found else { return nil }
        }
        guard !servers.isEmpty, servers.count <= 32, proxy == nil || servers.contains(where: { $0.turn && $0.tcp }),
              (allowsP2P && proxy == nil) || servers.contains(where: \.turn) else { return nil }
        self.version = version; self.key = key; self.fingerprint = fingerprint; self.outgoing = outgoing; self.video = video
        self.allowP2P = allowsP2P && proxy == nil; self.maxLayer = maxLayer; self.servers = servers; self.proxy = proxy
    }
}
