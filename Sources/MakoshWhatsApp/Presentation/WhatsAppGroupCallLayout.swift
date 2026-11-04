import Foundation

package struct WhatsAppGroupCallLayout: Sendable {
  package let participants: [WhatsAppCallParticipant]
  package var page = 0, pinned: String?
  package init(participants: [WhatsAppCallParticipant], page: Int = 0, pinned: String? = nil) {
    self.participants = participants
    self.page = page
    self.pinned = pinned
  }
  package var remotes: [WhatsAppCallParticipant] { participants.filter { $0.me != true } }
  package var pageCount: Int {
    let n = remotes.count - (pinned.flatMap { id in remotes.first { $0.jid == id } } == nil ? 0 : 1)
    let size = pinned == nil ? 9 : 8
    return max(1, (n + size - 1) / size)
  }
  package var visibleParticipants: [WhatsAppCallParticipant] {
    let fixed = pinned.flatMap { id in remotes.first { $0.jid == id } }
    let others = remotes.filter { $0.jid != fixed?.jid }
    let size = fixed == nil ? 9 : 8
    let start = min(max(0, page), pageCount - 1) * size
    return (fixed.map { [$0] } ?? []) + Array(others.dropFirst(start).prefix(size))
  }
  package var visibleStreams: [WhatsAppCallStreamID] {
    visibleParticipants.filter { $0.state == "connected" }.compactMap { p in
      p.devices.first.map { WhatsAppCallStreamID(sender: p.jid, device: $0.jid, pid: $0.pid) }
    }
  }

}
