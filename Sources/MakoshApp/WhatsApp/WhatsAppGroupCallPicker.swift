import Foundation
import MakoshWhatsApp
import SwiftUI

@MainActor final class WhatsAppGroupCallPickerModel: ObservableObject {
  @Published private(set) var members: [WhatsAppMember] = []
  @Published private(set) var selected: Set<String> = []
  @Published private(set) var groupJID: String?
  @Published private(set) var busy = false
  @Published private(set) var error: String?
  private var generation: UInt64 = 0
  private let worker: any WhatsAppServing
  init(worker: any WhatsAppServing) { self.worker = worker }
  func load(accountID: UUID, groupJID: String) async {
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
  func cancel() {
    generation &+= 1
    members = []
    selected = []
    busy = false
  }

  func toggle(_ jid: String) {
    guard members.contains(where: { $0.jid == jid }) else { return }
    if selected.contains(jid) {
      selected.remove(jid)
    } else if selected.count < 31 {
      selected.insert(jid)
    }
  }
  func targets() throws -> [String] {
    try WhatsAppGroupCallTargets.validate(members.filter { selected.contains($0.jid) }.map(\.jid))
  }
}

struct WhatsAppGroupCallPicker: View {
  @StateObject private var model: WhatsAppGroupCallPickerModel
  @Environment(\.dismiss) private var dismiss
  let accountID: UUID, groupJID: String, video: Bool
  let start: ([String]) -> Void
  init(
    worker: any WhatsAppServing, accountID: UUID, groupJID: String, video: Bool,
    start: @escaping ([String]) -> Void
  ) {
    _model = StateObject(wrappedValue: .init(worker: worker))
    self.accountID = accountID
    self.groupJID = groupJID
    self.video = video
    self.start = start
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(video ? "Групповой видеозвонок" : "Групповой аудиозвонок").font(.title2.bold())
      Text("Выберите от 2 до 31 собеседника. Вызов получат только выбранные участники.")
        .foregroundStyle(.secondary)
      if model.busy { ProgressView() }
      if let error = model.error { Text(error).foregroundStyle(.red) }
      List(model.members) { member in
        Toggle(
          member.jid,
          isOn: Binding(
            get: { model.selected.contains(member.jid) }, set: { _ in model.toggle(member.jid) })
        ).accessibilityIdentifier("whatsapp.group.choose." + member.jid)
      }.frame(minHeight: 220)
      HStack {
        Text("Выбрано: \(model.selected.count) / 31")
        Spacer()
        Button("Отмена") { dismiss() }
        Button("Позвонить") {
          if let targets = try? model.targets() {
            start(targets)
            dismiss()
          }
        }.disabled((try? model.targets()) == nil || model.busy)
      }
    }.padding(24).frame(width: 500, height: 440).task {
      await model.load(accountID: accountID, groupJID: groupJID)
    }.onDisappear { model.cancel() }
  }
}
