# SPDX-License-Identifier: GPL-3.0-or-later
"""Pinned Telegram-iOS a24bbe45 update-replay visibility adaptation.

Upstream authorship/license retained; ANCHOR is an exact patch context.
"""
STATE_MANAGER = "submodules/TelegramCore/Sources/State/AccountStateManager.swift"
ANCHOR = """    func addUpdates(_ updates: Api.Updates) {
        self.impl.with { impl in
            impl.addUpdates(updates)
        }
    }"""


def adapt_peer_management_source(relative, source):
    if relative != STATE_MANAGER:
        return source
    if source.count(ANCHOR) != 1:
        raise RuntimeError("Unexpected peer-management update-replay context")
    return source.replace(ANCHOR, ANCHOR.replace("    func addUpdates", "    public func addUpdates", 1))
