# SPDX-License-Identifier: GPL-3.0-or-later
"""Exact-source adaptation of the pinned Postbox pending-read table.

Upstream: overtake/Telegram-iOS a24bbe45f9861f736a79916a50898512f751e0dc.
Retains upstream authorship/license; snippets below are patch contexts.
"""
import hashlib

READ_SYNC = "submodules/Postbox/Sources/MessageHistorySynchronizeReadStateTable.swift"
SOURCE_SHA256 = "38d4c2bbc8f42742a15a7b0b1308c0f3c92fbd81126cea1194e0bb0f45296dfa"
ADAPTED_SHA256 = "4de32291e4d9773a4af00214d486ec433de17aacbae5462c6a74fbd099cc61a0"


def adapt_read_source(source: str) -> str:
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == ADAPTED_SHA256:
        return source
    if digest != SOURCE_SHA256:
        raise ValueError("Unexpected pinned Postbox read synchronization source digest")
    old = "self.valueBox.range(self.table, start: self.lowerBound(), end: self.upperBound(), values: { key, value in\n            let peerId = PeerId(key.getInt64(0))"
    new = "self.valueBox.scanInt64(self.table, values: { key, value in\n            let peerId = PeerId(key)"
    if source.count(old) != 1 or source.count("        }, limit: 0)") != 1:
        raise ValueError("Unexpected pinned Postbox read synchronization patch context")
    # The full-table operation needs no bounds. scanInt64 preserves integer keys;
    # generic scan reads binary keys and is unsuitable for this SQLite table.
    adapted = source.replace(old, new).replace("        }, limit: 0)", "        })")
    if hashlib.sha256(adapted.encode()).hexdigest() != ADAPTED_SHA256:
        raise ValueError("Unexpected adapted Postbox read synchronization digest")
    return adapted
