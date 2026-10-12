# SPDX-License-Identifier: GPL-3.0-or-later
"""Expose pinned draft helpers and invalidate a live view for changed input bytes.

Upstream: overtake/Telegram-iOS a24bbe45f9861f736a79916a50898512f751e0dc.
"""
import hashlib

DRAFT_HELPERS = {
    "submodules/TelegramCore/Sources/SyncCore/SyncCore_SynchronizeableChatInputState.swift": (
        "245c506f862846061a5c40bdd6b5f7c64ee094773605f97083fe97a81871669b",
        "a1a58ec488a9822270a9768d989b62a0877e879d284db03f8afebbb856ca010d",
        "func _internal_updateChatInputState(", "public func _internal_updateChatInputState("),
    "submodules/TelegramCore/Sources/State/SynchronizeChatInputStateOperation.swift": (
        "b9862d39d04bba8702e9d1f6b175163e3833160711ffcd1292c72e509495b817",
        "32744a1bdead7bdc1b201b81cc81f008c4a0dac0a9645e397955c5d60ec0cead",
        "func addSynchronizeChatInputStateOperation(", "public func addSynchronizeChatInputStateOperation("),
    "submodules/Postbox/Sources/PeerChatInterfaceStateTable.swift": (
        "71503450626ce23d3f5d0f3fa64ce49382794e2f6576af9380881163323b72d7",
        "4420a7124408108250fa0747dc56d74f2539ea63065ff8cf0b58fc4f09770c5c",
        "currentState.overrideChatTimestamp != state.overrideChatTimestamp",
        "currentState.overrideChatTimestamp != state.overrideChatTimestamp || currentState.data != state.data"),
}


def adapt_draft_source(path: str, source: str) -> str:
    original, adapted, declaration, replacement = DRAFT_HELPERS[path]
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == adapted:
        return source
    if digest != original or source.count(declaration) != 1:
        raise ValueError("Unexpected pinned Telegram draft helper source")
    result = source.replace(declaration, replacement)
    if hashlib.sha256(result.encode()).hexdigest() != adapted:
        raise ValueError("Unexpected adapted Telegram draft helper source")
    return result
