import MakoshWhatsApp
import SwiftUI

/// The immutable source survives account selection while the sheet is open.
struct WhatsAppRichComposeView: View {
  let model: WhatsAppWorkspaceModel, accountID: UUID, chatID: String
  @Environment(\.dismiss) private var dismiss
  @State private var kind = "location"
  @State private var text = ""
  @State private var first = ""
  @State private var second = ""
  @State private var options = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Сообщение WhatsApp").font(.title2.bold())
        Spacer()
        Button("Отмена") { dismiss() }
      }
      Picker("Тип", selection: $kind) {
        Text("Геопозиция").tag("location")
        Text("Контакт").tag("contact")
        Text("Опрос").tag("poll")
      }.pickerStyle(.segmented)
      TextField(
        kind == "poll" ? "Вопрос" : kind == "contact" ? "Имя контакта" : "Подпись", text: $text
      ).textFieldStyle(.roundedBorder)
      if kind == "location" {
        TextField("Широта, например 40.4168", text: $first)
        TextField("Долгота, например -3.7038", text: $second)
      } else if kind == "contact" {
        TextField("Номер в международном формате, +…", text: $first)
      } else {
        Text("От 2 до 12 вариантов, по одному в строке").foregroundStyle(.secondary)
        TextEditor(text: $options).frame(height: 150)
      }
      if let error = model.actions.error { Text(error).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Отправить") { send() }.disabled(action == nil || model.actions.busy)
      }
    }.textFieldStyle(.roundedBorder).padding(24).frame(width: 480)
  }
  private var action: WhatsAppAction? {
    if kind == "location" {
      guard let lat = Double(first.replacingOccurrences(of: ",", with: ".")),
        let lon = Double(second.replacingOccurrences(of: ",", with: ".")), (-90...90).contains(lat),
        (-180...180).contains(lon)
      else { return nil }
      var a = WhatsAppAction(.location, text: text)
      a.latitude = lat
      a.longitude = lon
      return a
    }
    if kind == "contact" {
      let number = first.filter { $0.isNumber }
      guard (7...15).contains(number.count),
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        !text.contains(where: { $0.isNewline }), !text.contains(";")
      else { return nil }
      var a = WhatsAppAction(.contact, text: text)
      a.to = number + "@s.whatsapp.net"
      a.value = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:\(text)\r\nTEL;TYPE=CELL:+\(number)\r\nEND:VCARD"
      return a
    }
    let values = options.split(whereSeparator: \.isNewline).map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard (2...12).contains(values.count), Set(values).count == values.count,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    var a = WhatsAppAction(.poll, text: text)
    a.options = values
    return a
  }
  private func send() {
    guard let action else { return }
    Task {
      if await model.actions.perform(action, expectedAccount: accountID, expectedChat: chatID)
        != nil
      {
        dismiss()
        await model.refresh()
        await model.composer.refreshOutbox()
      }
    }
  }
}
struct WhatsAppNewChatView: View {
  @ObservedObject var model: WhatsAppWorkspaceModel
  let accountID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var group = false
  @State private var title = ""
  @State private var target = ""
  @State private var busy = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Новый чат").font(.title2.bold())
      Toggle("Создать группу", isOn: $group)
      if group {
        TextField("Название группы", text: $title)
        TextField("Участники: номера +… или JID через запятую", text: $target)
      } else {
        TextField("Номер +… или JID", text: $target)
      }
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Button("Отмена") { dismiss() }
        Spacer()
        Button(group ? "Создать" : "Открыть") { Task { await open() } }.disabled(
          busy || targets.isEmpty
            || group && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 500).textFieldStyle(.roundedBorder)
  }
  private var targets: [String] {
    target.split(separator: ",").compactMap { raw in
      let s = raw.trimmingCharacters(in: .whitespaces)
      if s.hasSuffix("@lid") || s.hasSuffix("@s.whatsapp.net") { return s }
      let digits = s.filter(\.isNumber)
      return (7...15).contains(digits.count) ? digits + "@s.whatsapp.net" : nil
    }
  }
  private func open() async {
    guard model.selectedAccountID == accountID, !targets.isEmpty else { return }
    busy = true
    defer { busy = false }
    do {
      let jid: String
      if group {
        var a = WhatsAppAction(.groupCreate, text: title)
        a.mentions = targets
        let result = try await model.notificationWorker.perform(
          accountID: accountID, chat: "self@lid", action: a)
        guard let created = result.info?.jid else { throw WhatsAppFailure.notAdmitted }
        jid = created
      } else {
        guard targets.count == 1 else { throw WhatsAppFailure.invalid }
        jid = targets[0]
      }
      try await model.notificationWorker.openChat(accountID: accountID, chat: jid)
      guard model.selectedAccountID == accountID else { return }
      await model.refresh()
      await model.selectChat(jid)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}
