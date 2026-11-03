import Postbox
import TelegramCore

/// Both the native seed renderer and application admission use this checked boundary.
nonisolated func telegramForumTopicData(_ entry: CodableEntry) -> MessageHistoryThreadData? {
    _makoshDecodeMessageHistoryThreadData(entry)
}
