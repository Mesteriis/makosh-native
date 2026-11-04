import Foundation
import MakoshWhatsApp
import SwiftUI

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
