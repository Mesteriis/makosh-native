import Postbox
import TelegramCore

func telegramSearchNavigationThread(peer: Peer?, threadID: Int64?) -> Int64? {
    guard let channel = peer as? TelegramChannel,
          channel.flags.contains(.isForum), !channel.flags.contains(.isMonoforum),
          let threadID, threadID > 0, Int32(exactly: threadID) != nil else { return nil }
    return threadID
}
