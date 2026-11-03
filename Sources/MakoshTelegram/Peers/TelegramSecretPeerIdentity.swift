import Postbox
import TelegramCore

/// Secret API IDs are signed Int32; their packed Postbox identity stays positive.
/// Parse the bounded raw representation before a native roundtrip assertion.
nonisolated func telegramSecretPeerID(_ raw: Int64) -> PeerId? {
    let bits = UInt64(bitPattern: raw)
    // The pinned Postbox Peer.swift reserves native namespace3 for signed IDs.
    guard bits >> 32 == 3 else { return nil }
    let nativeID = Int32(bitPattern: UInt32(truncatingIfNeeded: bits))
    guard nativeID != 0 else { return nil }
    return PeerId(namespace: Namespaces.Peer.SecretChat, id: ._internalFromInt64Value(Int64(nativeID)))
}
