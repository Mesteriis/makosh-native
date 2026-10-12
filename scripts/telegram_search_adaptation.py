# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded adaptation of TelegramCore SearchMessages.swift.

Upstream: overtake/Telegram-iOS a24bbe45f9861f736a79916a50898512f751e0dc.
Retains upstream authorship/license; snippets below are patch contexts.
"""
import hashlib

SOURCE_SHA256 = "95efe273533cbfe3d6c9893dc28baed34ea9a24754cdda8c73612178a82eddb7"
ADAPTED_SHA256 = "ef63477bc9b78d5b16c6bd5cd568f683037882a8411b601e1b0a7952f9c077fa"

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
    adapted = prefix + REDUCER + body + suffix
    if hashlib.sha256(adapted.encode()).hexdigest() != ADAPTED_SHA256:
        raise ValueError("Unexpected adapted Telegram search source digest")
    return adapted
