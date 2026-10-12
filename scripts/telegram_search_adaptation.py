# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded adaptation of TelegramCore SearchMessages.swift.

Upstream: overtake/Telegram-iOS a24bbe45f9861f736a79916a50898512f751e0dc.
Retains upstream authorship/license; snippets below are patch contexts.
"""
import hashlib

SOURCE_SHA256 = "95efe273533cbfe3d6c9893dc28baed34ea9a24754cdda8c73612178a82eddb7"
ADAPTED_SHA256 = "a541b8adfcb38b314ca6cedafb2678bc9efc7f17a9f3674d19e9a6fdb1198632"

REDUCER = '''// Makosh: distinguish deliberately skipped requests from failed RPCs.
enum MakoshSearchRequestOutcome {
    case skipped
    case success(Api.messages.Messages)
    case failed

    var result: Api.messages.Messages? {
        if case let .success(result) = self { return result }
        return nil
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// A failed pair must never advance either cursor, including migrated peers.
func makoshSearchFailure(previous: SearchMessagesState?, main: MakoshSearchRequestOutcome,
                         additional: MakoshSearchRequestOutcome) -> (SearchMessagesResult, SearchMessagesState)? {
    guard main.isFailure || additional.isFailure else { return nil }
    let retained = previous ?? SearchMessagesState(main: SearchMessagesPeerState(
        messages: [], readStates: [:], threadInfo: [:], totalCount: 0,
        completed: false, nextRate: nil), additional: nil)
    let visible = mergedResult(retained)
    return (SearchMessagesResult(messages: visible.messages, readStates: visible.readStates,
        threadInfo: visible.threadInfo, totalCount: visible.totalCount, completed: false,
        searchFailed: true), retained)
}

// Saved/monoforum thread identifiers encode cloud peers, not message ids.
// Validate the namespace/id bits before PeerId's legacy-sentinel assertion can run.
func makoshSearchSubPeerId(_ threadId: Int64) -> PeerId? {
    let bits = UInt64(bitPattern: threadId)
    guard bits >> 59 == 0 else { return nil }
    let namespace = PeerId.Namespace._internalFromInt32Value(Int32((bits >> 32) & 7))
    guard namespace == Namespaces.Peer.CloudUser || namespace == Namespaces.Peer.CloudGroup
            || namespace == Namespaces.Peer.CloudChannel,
          bits & ~(UInt64(7) << 32) != 0 else {
        return nil
    }
    return PeerId(threadId)
}

func makoshSearchInputIsValid(peer: Peer, accountPeerId: PeerId, fromId: PeerId?,
                              from: Peer?, threadId: Int64?, subPeer: Peer?) -> Bool {
    guard apiInputPeer(peer) != nil else { return false }
    if let fromId {
        guard let from, from.id == fromId, apiInputPeer(from) != nil else { return false }
    } else if from != nil {
        return false
    }
    guard let threadId else { return subPeer == nil }
    if peer.id == accountPeerId || peer.isMonoForum {
        guard let expectedSubPeerId = makoshSearchSubPeerId(threadId), let subPeer,
              subPeer.id == expectedSubPeerId, apiInputPeer(subPeer) != nil else { return false }
        return true
    }
    return subPeer == nil && threadId > 0 && threadId <= Int64(Int32.max)
}

// Keep local secret-message lookup at the same scope boundary as the global merger.
func makoshSearchLocalSecretMessages(transaction: Transaction, location: SearchMessagesLocation,
                                     query: String, tags: MessageTags?) -> [Message] {
    if case let .general(scope, _, _, _) = location {
        switch scope {
        case .channels, .groups:
            return []
        case .everywhere, .privateChats:
            break
        }
    }
    let messages = transaction.searchMessages(peerId: nil, query: query, tags: tags)
    guard let tags else { return messages }
    // Postbox's global FTS branch ignores tags; filter before constructing merged state/counts.
    return messages.filter { !$0.tags.intersection(tags).isEmpty }
}

'''


def _replace(source: str, old: str, new: str, count: int = 1) -> str:
    if source.count(old) != count:
        raise ValueError("Unexpected pinned Telegram search adaptation context")
    return source.replace(old, new)


def adapt_search_source(source: str) -> str:
    digest = hashlib.sha256(source.encode()).hexdigest()
    if digest == ADAPTED_SHA256:
        return source
    if digest != SOURCE_SHA256:
        raise ValueError("Unexpected pinned Telegram search source digest")
    source = _replace(source, "private struct SearchMessagesPeerState", "struct SearchMessagesPeerState")
    source = _replace(source, "fileprivate let main: SearchMessagesPeerState", "let main: SearchMessagesPeerState")
    source = _replace(source, "fileprivate let additional: SearchMessagesPeerState?", "let additional: SearchMessagesPeerState?")
    source = _replace(source, "public struct SearchMessagesResult: Equatable {", "public struct SearchMessagesResult: Equatable {\n    public let searchFailed: Bool")
    source = _replace(source, "totalCount: Int32, completed: Bool) {", "totalCount: Int32, completed: Bool, searchFailed: Bool = false) {")
    source = _replace(source, "        self.completed = completed\n", "        self.completed = completed\n        self.searchFailed = searchFailed\n")
    source = _replace(source, "    public static func ==(lhs: SearchMessagesResult, rhs: SearchMessagesResult) -> Bool {", "    public static func ==(lhs: SearchMessagesResult, rhs: SearchMessagesResult) -> Bool {\n        if lhs.searchFailed != rhs.searchFailed || lhs.completed != rhs.completed || lhs.totalCount != rhs.totalCount {\n            return false\n        }")
    start = source.index("func _internal_searchMessages(")
    end = source.index("func _internal_searchHashtagPosts(", start)
    prefix, body, suffix = source[:start], source[start:end], source[end:]
    body = _replace(body, "(Api.messages.Messages?, Api.messages.Messages?)", "(MakoshSearchRequestOutcome, MakoshSearchRequestOutcome)", 4)
    body = _replace(body, "Signal<Api.messages.Messages?, NoError>", "Signal<MakoshSearchRequestOutcome, NoError>", 6)
    body = _replace(body, "|> map(Optional.init)", "|> map(MakoshSearchRequestOutcome.success)", 3)
    # Only catch bodies become failures. Deliberate skips remain non-failures.
    body = _replace(body, "return .single((nil, nil))", "return .single((.failed, .skipped))", 3)
    for indent in ("                        ", "                            ", "                    "):
        old = "|> `catch` { _ -> Signal<MakoshSearchRequestOutcome, NoError> in\n" + indent + "return .single(nil)"
        body = _replace(body, old, old.replace(".single(nil)", ".single(.failed)"))
    body = _replace(body, ".single(nil)", ".single(.skipped)", 6)
    body = _replace(body, "return (result, nil)", "return (.success(result), .skipped)")
    body = _replace(body, "        return account.postbox.transaction { transaction -> (SearchMessagesResult, SearchMessagesState) in\n            var additional:", "        return account.postbox.transaction { transaction -> (SearchMessagesResult, SearchMessagesState) in\n            if let failure = makoshSearchFailure(previous: state, main: result, additional: additionalResult) {\n                return failure\n            }\n            var additional:")
    body = _replace(body, "result: additionalResult)", "result: additionalResult.result)")
    body = _replace(body, "result: result) ?? SearchMessagesPeerState", "result: result.result) ?? SearchMessagesPeerState")
    body = _replace(body, '                        let secretMessages: [Message]\n                        if case let .general(scope, _, _, _) = location, case .channels = scope {\n                            secretMessages = []\n                        } else {\n                            secretMessages = transaction.searchMessages(peerId: nil, query: query, tags: tags)\n                        }',
                    '                        let secretMessages = makoshSearchLocalSecretMessages(transaction: transaction,\n                            location: location, query: query, tags: tags)')
    body = _replace(body, '                    subPeer = transaction.getPeer(PeerId(threadId))',
                    '                    guard let subPeerId = makoshSearchSubPeerId(threadId) else { return nil }\n                    subPeer = transaction.getPeer(subPeerId)')
    body = _replace(body, '                let peer = values.peer\n                guard let inputPeer = apiInputPeer(peer) else {',
                    '                let peer = values.peer\n                guard makoshSearchInputIsValid(peer: peer, accountPeerId: account.peerId,\n                    fromId: fromId, from: values.from, threadId: threadId, subPeer: values.subPeer),\n                    let inputPeer = apiInputPeer(peer) else {')
    adapted = prefix + REDUCER + body + suffix
    if hashlib.sha256(adapted.encode()).hexdigest() != ADAPTED_SHA256:
        raise ValueError("Unexpected adapted Telegram search source digest")
    return adapted
