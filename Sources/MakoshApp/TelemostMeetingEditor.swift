import SwiftUI
import MakoshTelemost

struct TelemostAddLinkView: View {
    @ObservedObject var model: TelemostWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Добавить встречу").font(.title2.bold())
            TextField("https://telemost.yandex.ru/j/…", text: $text).textFieldStyle(.roundedBorder).accessibilityIdentifier("telemost.link")
            Text("Ссылка сохраняется в выбранном каталоге. Добавление не открывает встречу и не проверяет доступ.").foregroundStyle(.secondary)
            HStack { Button("Отмена") { dismiss() }; Spacer(); Button("Сохранить ссылку") { Task { await model.addLink(text); if model.error == nil { dismiss() } } }.disabled(model.busy || (try? TelemostMeetingURL(text)) == nil) }
        }.padding(24).frame(width: 540)
    }
}
struct TelemostCreateView: View {
    @ObservedObject var model: TelemostWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Создать встречу через API").font(.title2.bold())
            TelemostWaitingPicker(value: Binding(get: { model.draft?.waitingRoom ?? .admins }, set: { model.draft = .init(waitingRoom: $0) }))
            Text("API получит только выбранный режим зала ожидания. Локальное название и заметки можно добавить после создания.").foregroundStyle(.secondary)
            HStack { Button("Закрыть") { dismiss() }; Spacer(); Button("Создать встречу") { if let draft = model.draft { Task { await model.create(request: draft); if model.draft == nil { dismiss() } } } }.disabled(model.busy || !model.can(.create)) }
            if let notice = model.notice { Text(notice).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
        }.padding(24).frame(width: 540)
    }
}
struct TelemostWaitingPicker: View {
    @Binding var value: TelemostWaitingRoom
    var body: some View { Picker("Зал ожидания", selection: $value) { Text(TelemostWaitingRoom.admins.title).tag(TelemostWaitingRoom.admins); Text(TelemostWaitingRoom.organization.title).tag(TelemostWaitingRoom.organization); Text(TelemostWaitingRoom.publicAccess.title).tag(TelemostWaitingRoom.publicAccess) } }
}
struct TelemostWaitingRoomView: View {
    @ObservedObject var model: TelemostWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var value = TelemostWaitingRoom.admins
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Изменить зал ожидания").font(.title2.bold()); TelemostWaitingPicker(value: $value)
            Text("Изменится только waiting_room_level; остальные сведения API не отправляются.").foregroundStyle(.secondary)
            HStack { Button("Отмена") { dismiss() }; Spacer(); Button("Применить") { let submitted = value; Task { if await model.update(patch: .init(waitingRoom: submitted)), value == submitted { dismiss() } } }.disabled(model.busy || !model.can(.update)) }
            if let notice = model.notice { Text(notice).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
        }.padding(24).frame(width: 520).onAppear { value = model.selectedMeeting?.conference?.waitingRoom ?? .admins }
    }
}
struct TelemostMeetingEditor: View {
    @ObservedObject var model: TelemostWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var value: TelemostLocalMeeting
    init(model: TelemostWorkspaceModel, meeting: TelemostLocalMeeting) { self.model = model; _value = State(initialValue: meeting) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Локальные сведения").font(.title2.bold())
            TextField("Название", text: $value.localTitle).textFieldStyle(.roundedBorder)
            TextField("Заметки", text: $value.notes, axis: .vertical).lineLimit(4...12).textFieldStyle(.roundedBorder)
            Toggle("Избранное", isOn: $value.starred); Toggle("Скрыть из основного просмотра", isOn: $value.hidden)
            Text("Скрытие сохраняет историю. Включите «Показать скрытые» в каталоге, чтобы увидеть их снова.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Отмена") { dismiss() }; Spacer(); Button("Сохранить локально") { Task { await model.saveLocal(value); if model.error == nil { dismiss() } } }.disabled(model.busy) }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
        }.padding(24).frame(width: 560)
    }
}
