import SwiftUI
import MakoshCore
import MakoshTelemost

struct TelemostCatalogueView: View {
    @ObservedObject var model: TelemostWorkspaceModel
    @State private var accountSheet = false
    @State private var linkSheet = false
    @State private var createSheet = false
    @State private var operationsSheet = false
    @State private var showHidden = false
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Телемост").font(.title2.bold()); Spacer(); Button { accountSheet = true } label: { Image(systemName: "person.badge.plus") }.help("Добавить аккаунт API").disabled(!model.ready) }
            Picker("Каталог", selection: Binding(get: { model.selectedAccountID }, set: { id in Task { await model.selectAccount(id) } })) {
                Text("Ссылки без аккаунта").tag(UUID?.none)
                ForEach(model.accounts) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("telemost.accounts")
            if model.selectedAccountID != nil { Text(model.connection.title).font(.caption).foregroundStyle(.secondary) }
            TextField("Поиск встреч и заметок", text: $model.query).textFieldStyle(.roundedBorder).onSubmit { Task { await model.reload() } }.accessibilityIdentifier("telemost.search")
            HStack {
                Button("Добавить ссылку") { linkSheet = true }.disabled(!model.ready)
                Button("Создать") { if model.draft == nil { model.draft = .init(waitingRoom: .admins) }; createSheet = true }.disabled(!model.can(.create) || model.busy)
                Button { operationsSheet = true } label: { Image(systemName: "list.bullet.rectangle") }.help("Журнал операций")
            }
            Toggle("Показать скрытые", isOn: $showHidden).font(.caption)
            List(selection: Binding(get: { model.selectedMeetingID }, set: { model.selectMeeting($0) })) {
                ForEach(model.meetings.filter { showHidden || !$0.hidden }) { meeting in
                    HStack {
                        Image(systemName: meeting.starred ? "star.fill" : meeting.hidden ? "eye.slash" : "video")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.localTitle.isEmpty ? meeting.validatedURL.conferenceID : meeting.localTitle).lineLimit(1)
                            Text(meeting.unavailable ? "Недоступна · история сохранена" : meeting.conference == nil ? "Сохранённая ссылка" : "Данные API сохранены").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(meeting.id).accessibilityIdentifier("telemost.meeting.\(meeting.validatedURL.conferenceID)")
                }
                if model.hasMore { Button("Ещё встречи") { Task { await model.reload(more: true) } }.accessibilityIdentifier("telemost.more") }
            }.listStyle(.plain)
            if model.isSynthetic { Text("СИНТЕТИЧЕСКАЯ ПРОВЕРКА · Яндекс не подключён").font(.caption2.bold()).foregroundStyle(.orange) }
        }.padding(16)
        .task {
            while !Task.isCancelled {
                await model.refreshState()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
        .sheet(isPresented: $accountSheet) { TelemostConnectionView(model: model, configuration: true) }
        .sheet(isPresented: $linkSheet) { TelemostAddLinkView(model: model) }
        .sheet(isPresented: $createSheet) { TelemostCreateView(model: model) }
        .sheet(isPresented: $operationsSheet) { TelemostOperationsView(model: model) }
    }
}

struct TelemostDetailView: View {
    @ObservedObject var model: TelemostWorkspaceModel
    let contacts: [Contact]
    let dossier: (UUID) -> Void
    @State private var connectionSheet = false
    @State private var editSheet = false
    @State private var waitingSheet = false
    @State private var historySheet = false
    @State private var contactID: UUID?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Label("Яндекс Телемост", systemImage: "video").font(.title.bold()); Spacer()
                    if model.selectedAccountID != nil { Button("Аккаунт") { connectionSheet = true } }
                    Button("Экспорт…") { Task { if let url = await TelemostExportPanel.choose(synthetic: model.isSynthetic) { await model.exportHistory(to: url) } } }.disabled(!model.ready || model.busy)
                }
                Text((model.isSynthetic ? "QA · подставные данные; Яндекс не подключён. " : "") + "Каталог содержит встречи, созданные или добавленные в Макоше. Участие открывается в официальном клиенте или браузере.").foregroundStyle(.secondary)
                if let meeting = model.selectedMeeting {
                    Text(meeting.localTitle.isEmpty ? "Встреча" : meeting.localTitle).font(.title2.bold()).textSelection(.enabled)
                    Text(meeting.validatedURL.url.absoluteString).textSelection(.enabled).accessibilityIdentifier("telemost.selectedURL")
                    HStack {
                        Button("Открыть встречу") { model.openMeeting(meeting.validatedURL.url.absoluteString) }.buttonStyle(.borderedProminent).accessibilityIdentifier("telemost.open")
                        Button("Скопировать ссылку") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(meeting.validatedURL.url.absoluteString, forType: .string) }
                        Button("Изменить локально") { editSheet = true }.disabled(model.busy)
                    }
                    GroupBox("Сведения") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(meeting.conference == nil ? "Ссылка сохранена локально; доступность API ещё не проверена." : "Наблюдение API: \(meeting.conference!.observedAt.formatted())")
                            if meeting.unavailable { Text("API сообщил о недоступности. Сохранённые версии остаются в архиве.").foregroundStyle(.orange) }
                            if let conference = meeting.conference {
                                Text("Зал ожидания: \(conference.waitingRoom?.title ?? "Неизвестное значение: " + conference.waitingRoomRaw)")
                                Text(meeting.cohostsComplete ? "Соорганизаторы · полный полученный список" : "Соорганизаторы · список неполный, нужно продолжить обновление")
                                ForEach(meeting.cohosts, id: \.self) { Text($0).textSelection(.enabled) }
                            }
                            HStack {
                                Button("Обновить известную встречу") { Task { await model.refreshSelected() } }.disabled(!model.can(.read) || model.busy)
                                Button("Зал ожидания…") { waitingSheet = true }.disabled(meeting.scope == nil || !model.can(.update) || model.busy)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    if !meeting.notes.isEmpty { Text(meeting.notes).textSelection(.enabled) }
                    HStack { if meeting.starred { Label("Избранное", systemImage: "star.fill") }; if meeting.hidden { Label("Скрыта в каталоге; сохранена", systemImage: "eye.slash") }; Spacer(); Button("История версий") { historySheet = true } }
                    GroupBox("Связать с досье") {
                        HStack {
                            Picker("Контакт", selection: $contactID) { Text("Выберите контакт").tag(UUID?.none); ForEach(contacts) { Text($0.displayName).tag(Optional($0.id)) } }
                            Button("Добавить ссылку и открыть") { if let contactID { dossier(contactID) } }.disabled(contactID == nil || model.busy).accessibilityIdentifier("telemost.dossier")
                        }.padding(8)
                    }
                } else {
                    ContentUnavailableView("Выберите встречу", systemImage: "video", description: Text("Добавьте свою ссылку без входа или подключите доступный вашей организации API аккаунта."))
                }
                if let notice = model.notice { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("telemost.notice") }
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $connectionSheet) { TelemostConnectionView(model: model, configuration: false) }
        .sheet(isPresented: $editSheet) { if let meeting = model.selectedMeeting { TelemostMeetingEditor(model: model, meeting: meeting) } }
        .sheet(isPresented: $waitingSheet) { TelemostWaitingRoomView(model: model) }
        .sheet(isPresented: $historySheet) { TelemostHistoryView(model: model) }
        .alert("Телемост", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("Понятно") { model.error = nil } } message: { Text(model.error ?? "") }
        .onChange(of: model.contextID) { _, _ in contactID = nil; editSheet = false; waitingSheet = false; historySheet = false; connectionSheet = false }
    }
}
