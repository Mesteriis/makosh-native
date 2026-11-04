import Foundation

@MainActor package final class WhatsAppGroupCallPickerModel: ObservableObject {
  @Published package private(set) var members: [WhatsAppMember] = []
  @Published package private(set) var selected: Set<String> = []
  @Published package private(set) var groupJID: String?
  @Published package private(set) var busy = false
  @Published package private(set) var error: String?
  private var generation: UInt64 = 0
  private let worker: any WhatsAppServing
  package init(worker: any WhatsAppServing) { self.worker = worker }
  package func load(accountID: UUID, groupJID: String) async {
    generation &+= 1
    let token = generation
    self.groupJID = groupJID
    members = []
    selected = []
    busy = true
    error = nil
    do {
      let info = try await worker.info(accountID: accountID, chat: groupJID, operation: .groupInfo)
      guard token == generation, self.groupJID == groupJID, !Task.isCancelled else { return }
      guard info.jid == groupJID, let source = info.members, source.count <= 10000 else {
        throw WhatsAppFailure.invalid
      }
      let own = Set(source.filter(\.me).map(\.jid))
      var seen = Set<String>()
      members = source.filter {
        !$0.me && !own.contains($0.jid) && WhatsAppGroupCallTargets.isUser($0.jid)
          && seen.insert($0.jid).inserted
      }
    } catch {
      if token == generation && !Task.isCancelled { self.error = error.localizedDescription }
    }
    if token == generation { busy = false }
  }
  package func cancel() {
    generation &+= 1
    members = []
    selected = []
    busy = false
  }

  package func toggle(_ jid: String) {
    guard members.contains(where: { $0.jid == jid }) else { return }
    if selected.contains(jid) {
      selected.remove(jid)
    } else if selected.count < 31 {
      selected.insert(jid)
    }
  }
  package func targets() throws -> [String] {
    try WhatsAppGroupCallTargets.validate(members.filter { selected.contains($0.jid) }.map(\.jid))
  }
}
