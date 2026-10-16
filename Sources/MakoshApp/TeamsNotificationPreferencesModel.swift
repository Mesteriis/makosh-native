import Combine
import Foundation
import MakoshTeams

@MainActor final class TeamsNotificationPreferencesModel: ObservableObject {
  @Published var rule = TeamsNotificationRule()
  @Published private(set) var loaded = false
  @Published private(set) var busy = false
  @Published var notice: String?
  private let worker: any TeamsNotificationServing
  private var scope: TeamsNotificationScope = .global
  private var generation: UInt64 = 0
  init(worker: any TeamsNotificationServing) { self.worker = worker }
  var canSave: Bool { loaded && !busy }
  func reset(_ scope: TeamsNotificationScope) {
    generation &+= 1
    self.scope = scope
    rule = .init()
    loaded = false
    busy = false
    notice = nil
  }
  func load(expectedScope: TeamsNotificationScope) async {
    guard scope == expectedScope else { return }
    let token = generation
    busy = true
    defer { if generation == token { busy = false } }
    do {
      let value = try await worker.savedNotificationRule(scope: expectedScope)
      guard generation == token, !Task.isCancelled else { return }
      rule = value
      loaded = true
    } catch { if generation == token { notice = error.localizedDescription } }
  }
  func save(expectedScope: TeamsNotificationScope) async {
    guard loaded, !busy, scope == expectedScope else { return }
    let token = generation
    let value = rule
    busy = true
    defer { if generation == token { busy = false } }
    do {
      try await worker.setNotificationRule(value, scope: expectedScope)
      if generation == token { notice = "Настройки сохранены" }
    } catch { if generation == token { notice = error.localizedDescription } }
  }
}
