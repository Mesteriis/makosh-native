# SPDX-License-Identifier: GPL-3.0-or-later
"""Fail-closed Postbox journal adaptation; pinned Telegram-iOS a24bbe45.

Retains upstream provenance. Only raw pinned or exact adapted inputs accepted.
Generated engine must be produced by preparation, never patched in place.
"""
import hashlib
from pathlib import Path

POSTBOX = 'submodules/Postbox/Sources/Postbox.swift'
HISTORY = 'submodules/Postbox/Sources/MessageHistoryTable.swift'
TEMPLATE = Path(__file__).resolve().parent / 'telegram-retention/MakoshMessageJournal.swift'
SOURCE_SHA256 = {'submodules/Postbox/Sources/Postbox.swift': '52f1aa3ff0af3f4e336c44fac6b0b2cebb79af1f339d690542a1b07116cece18', 'submodules/Postbox/Sources/MessageHistoryTable.swift': '674f602d5bfb6834c70421a6098605e24af2479b5745a4f83d17f52db44b42cb'}
ADAPTED_SHA256 = {'submodules/Postbox/Sources/Postbox.swift': 'aa46bdd69c1a5e1a47ea307f4967ac5484853026f7627f3b60c4380566f01dad', 'submodules/Postbox/Sources/MessageHistoryTable.swift': 'cf811fcd9b11b047914b570b812c50aefe471f98fc791789485f4e14654147be'}
TEMPLATE_SHA256 = 'c41d924306b4eac37fbaaf386dc94af685ace04630f518258351f137a61e9962'


def _replace(source: str, old: str, new: str, count: int = 1) -> str:
    if source.count(old) != count:
        raise ValueError('Unexpected pinned Postbox retention context')
    return source.replace(old, new)


def _transform(path: str, source: str) -> str:
    if path == POSTBOX:
        marker = '    public func addMessages(_ messages: [StoreMessage], location: AddMessagesLocation) -> [Int64: MessageId] {'
        api = '''    /// Durable local journal. Drain into archive, commit there, then acknowledge exact sequences.
    public func makoshArchiveJournal(limit: Int) throws -> [MakoshMessageJournalEntry] {
        guard !self.disposed, let postbox = self.postbox else { throw MakoshMessageJournalError.unavailable }
        return try MakoshMessageJournal(valueBox: postbox.valueBox).read(limit: limit)
    }

    public func acknowledgeMakoshArchiveJournal(sequences: [Int64]) throws {
        guard !self.disposed, let postbox = self.postbox else { throw MakoshMessageJournalError.unavailable }
        try MakoshMessageJournal(valueBox: postbox.valueBox).acknowledge(sequences: sequences)
    }

    /// Retain a scoped remote observation without inserting it into live history.
    public func makoshArchiveObserve(message: StoreMessage, removed: Bool) throws {
        guard !self.disposed, let postbox = self.postbox, case let .Id(id) = message.id,
              id.id > 0, id.peerId.id._internalGetInt64Value() > 0 else { throw MakoshMessageJournalError.unavailable }
        MakoshMessageJournal(valueBox: postbox.valueBox).append(id: id, timestamp: message.timestamp,
            text: message.text, authorId: message.authorId, flags: MessageFlags(message.flags),
            attributes: message.attributes, media: message.media, removed: removed)
    }

'''
        return _replace(source, marker, api + marker)
    if path != HISTORY:
        raise ValueError('Unknown Postbox retention source')
    marker = '    private let seedConfiguration: SeedConfiguration'
    helper = '''    private func makoshJournalCapture(_ message: IntermediateMessage, removed: Bool) {
        let media = self.renderMessageMedia(referencedMedia: message.referencedMedia,
            embeddedMediaData: message.embeddedMediaData)
        MakoshMessageJournal(valueBox: self.valueBox).append(id: message.id,
            timestamp: message.timestamp, text: message.text, authorId: message.authorId,
            flags: message.flags, attributes: MessageHistoryTable.renderMessageAttributes(message),
            media: media, removed: removed)
    }

    private func makoshJournalCapture(index: MessageIndex) {
        guard let message = self.getMessage(index) else { preconditionFailure("Makosh journal stored message missing") }
        self.makoshJournalCapture(message, removed: false)
    }

'''
    source = _replace(source, marker, helper + marker)
    marker = '            let message = self.readIntermediateEntry(key, value: value).message\n            let embeddedMediaData = message.embeddedMediaData'
    source = _replace(source, marker, marker.replace('\n            let embeddedMediaData', '\n            self.makoshJournalCapture(message, removed: true)\n            let embeddedMediaData'))
    marker = '        if let previousMessage = self.getMessage(index) {\n            var mediaToUpdate: [Media] = []'
    source = _replace(source, marker, marker.replace('\n            var mediaToUpdate', '\n            self.makoshJournalCapture(previousMessage, removed: false)\n            var mediaToUpdate'))
    marker = 'self.valueBox.set(self.table, key: self.key(message.index, key: sharedKey), value: sharedBuffer)'
    source = _replace(source, marker, marker + '\n        self.makoshJournalCapture(index: message.index)', 2)
    marker = 'self.valueBox.set(self.table, key: self.key(MessageIndex(id: message.id, timestamp: message.timestamp), key: sharedKey), value: sharedBuffer)'
    source = _replace(source, marker, marker + '\n        self.makoshJournalCapture(index: MessageIndex(id: message.id, timestamp: message.timestamp))')
    return source


def journal_source() -> str:
    source = TEMPLATE.read_text()
    if hashlib.sha256(source.encode()).hexdigest() != TEMPLATE_SHA256:
        raise ValueError('Postbox retention template drift')
    return source


def adapt_retention_source(path: str, source: str) -> str:
    digest = hashlib.sha256(source.encode()).hexdigest()
    if path not in SOURCE_SHA256:
        raise ValueError('Unknown Postbox retention source')
    if digest == ADAPTED_SHA256[path]:
        return source
    if digest != SOURCE_SHA256[path]:
        raise ValueError('Unexpected pinned Postbox retention source digest')
    adapted = _transform(path, source)
    if hashlib.sha256(adapted.encode()).hexdigest() != ADAPTED_SHA256[path]:
        raise ValueError('Unexpected adapted Postbox retention source digest')
    journal_source()
    return adapted
