# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded cached ID lookup after the pinned Postbox journal adaptation.

No history fetch, timestamp approximation or scan of the entire cached history.
The input and output hashes bind this composition to the reviewed preparation.
"""
import hashlib

POSTBOX = "submodules/Postbox/Sources/Postbox.swift"
SOURCE_SHA256 = "aa46bdd69c1a5e1a47ea307f4967ac5484853026f7627f3b60c4380566f01dad"
ADAPTED_SHA256 = "0b79868a70a8ca866f4aaa4776cd3cf88f37f7c64db457d144e4c4ccf60d7b11"
MARKER = "    public func getMessage(_ id: MessageId) -> Message? {"
API = '''    /// Cached ID-index lookup only: no history-hole or network operation.
    /// The exclusive upper bound preserves native selection range semantics.
    public func makoshCachedMessageIds(peerId: PeerId, namespace: MessageId.Namespace,
                                      lowerBound: MessageId.Id, upperBoundExclusive: MessageId.Id,
                                      limit: Int) -> [MessageId] {
        guard !self.disposed, let postbox = self.postbox, lowerBound > 0,
              lowerBound < upperBoundExclusive, limit > 0, limit <= 200 else { return [] }
        let upper = MessageId(peerId: peerId, namespace: namespace, id: upperBoundExclusive)
        return postbox.messageHistoryIndexTable.earlierEntries(id: upper, count: limit)
            .filter { $0.id.id >= lowerBound }.map { $0.id }
    }

'''


def adapt_selection_source(source: str) -> str:
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == ADAPTED_SHA256:
        return source
    if digest != SOURCE_SHA256 or source.count(MARKER) != 1:
        raise ValueError("Unexpected pinned Postbox selection input")
    adapted = source.replace(MARKER, API + MARKER)
    if hashlib.sha256(adapted.encode()).hexdigest() != ADAPTED_SHA256:
        raise ValueError("Unexpected adapted Postbox selection digest")
    return adapted


def strip_selection_source(source: str) -> str:
    """Verify the composed file before isolating the earlier journal for its tests."""
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == SOURCE_SHA256:
        return source
    if digest != ADAPTED_SHA256 or source.count(API) != 1:
        raise ValueError("Unexpected composed Postbox selection input")
    original = source.replace(API, "")
    if hashlib.sha256(original.encode()).hexdigest() != SOURCE_SHA256:
        raise ValueError("Unexpected isolated Postbox journal digest")
    return original
