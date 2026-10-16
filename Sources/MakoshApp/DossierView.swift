import SwiftUI
import MakoshCore
import MakoshTelemost

struct DossierView: View {
    let contact: Contact
    @ObservedObject var model: WorkspaceModel
    var openMeeting: (String) -> Void = { _ in }
    let edit: () -> Void
    @State private var note = ""
    @State private var noteSubmitting = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ДОСЬЕ КОНТАКТА").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                        Text(contact.displayName).font(.system(size: 30, weight: .semibold))
                        Text([contact.jobTitle, contact.organization].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Изменить", action: edit).disabled(!model.canWrite).accessibilityIdentifier("contact.edit")
                }
                if !contact.tags.isEmpty { Text(contact.tags.map { "#" + $0 }.joined(separator: "   ")).font(.callout).foregroundStyle(.indigo) }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(contact.emails, id: \.self) { value in Label(value, systemImage: "envelope").textSelection(.enabled) }
                        ForEach(contact.phones, id: \.self) { value in Label(value, systemImage: "phone").textSelection(.enabled) }
                        if contact.emails.isEmpty && contact.phones.isEmpty { Text("Почта и телефон пока не указаны").foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                } label: { Label("Как связаться", systemImage: "person.crop.circle") }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Заметки").font(.title3.weight(.semibold))
                    if contact.notes.isEmpty { Text("Контекст, который важно сохранить.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(contact.notes) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.text).textSelection(.enabled)
                            if item.source.identity.service == "telemost", let link = item.text.split(separator: "\n").compactMap({ try? TelemostMeetingURL(String($0)) }).first,
                               link.conferenceID.utf8.elementsEqual(item.source.identity.externalID.utf8) {
                                Button("Открыть встречу Телемоста") { openMeeting(link.url.absoluteString) }
                            }
                            Text("\(item.source.identity.service) · \(item.source.identity.accountID) · \(item.source.fetchedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                    TextField("Новая заметка", text: $note, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("contact.note")
                    HStack { Spacer(); Button("Добавить заметку") {
                        guard model.canWrite, !noteSubmitting else { return }
                        let text = note, id = contact.id
                        noteSubmitting = true
                        Task {
                            defer { noteSubmitting = false }
                            if await model.addNote(text, contactID: id), note == text, model.selectedID == id { note = "" }
                        }
                    }.disabled(!model.canWrite || noteSubmitting || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("contact.note.add") }
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        if contact.identities.isEmpty { Text("Добавлен вручную на этом Mac").foregroundStyle(.secondary) }
                        ForEach(contact.identities) { identity in
                            VStack(alignment: .leading, spacing: 4) { Text(identity.service).font(.headline); Text("Аккаунт: \(identity.accountID)"); Text("ID источника: \(identity.externalID)").font(.caption).textSelection(.enabled) }
                        }
                        ForEach(contact.observations) { item in
                            VStack(alignment: .leading, spacing: 4) { Text("\(fieldLabel(item.field)): \(item.value)"); Text("\(item.source.identity.service) · аккаунт \(item.source.identity.accountID) · запись \(item.source.identity.externalID) · \(item.source.fetchedAt.formatted())").font(.caption).foregroundStyle(.secondary) }
                        }
                    }.padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("Источники и аккаунты · \(contact.identities.count)", systemImage: "tray.full").font(.headline) }.accessibilityIdentifier("contact.sources")
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Text("История").font(.title3.weight(.semibold))
                    ForEach(contact.events.reversed()) { event in
                        HStack(alignment: .top, spacing: 12) { Image(systemName: "clock").foregroundStyle(.secondary); VStack(alignment: .leading, spacing: 4) { Text(event.detail); Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }
                    }
                    if contact.events.isEmpty { Text("Изменений пока нет").foregroundStyle(.secondary) }
                }
            }.padding(30).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color(nsColor: .textBackgroundColor).opacity(0.65)).id(contact.id)
    }
    private func fieldLabel(_ field: String) -> String {
        ["displayName": "Имя", "organization": "Компания", "jobTitle": "Должность", "phones": "Телефон", "emails": "Почта", "tags": "Метки"][field] ?? field
    }
}

struct ContactEditor: View {
    let contact: Contact?
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var organization: String
    @State private var job: String
    @State private var phones: String
    @State private var emails: String
    @State private var tags: String
    @State private var error: String?
    @State private var submitting = false
    init(contact: Contact?, model: WorkspaceModel) {
        self.contact = contact; self.model = model
        _name = State(initialValue: contact?.displayName ?? "")
        _organization = State(initialValue: contact?.organization ?? "")
        _job = State(initialValue: contact?.jobTitle ?? "")
        _phones = State(initialValue: contact?.phones.joined(separator: ", ") ?? "")
        _emails = State(initialValue: contact?.emails.joined(separator: ", ") ?? "")
        _tags = State(initialValue: contact?.tags.joined(separator: ", ") ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(contact == nil ? "Новый контакт" : "Изменить контакт").font(.title2.bold())
            Form {
                TextField("Имя", text: $name).accessibilityIdentifier("editor.name")
                TextField("Компания", text: $organization).accessibilityIdentifier("editor.organization")
                TextField("Должность", text: $job)
                TextField("Телефоны", text: $phones)
                TextField("Почта", text: $emails).accessibilityIdentifier("editor.email")
                TextField("Метки", text: $tags)
            }
            Text("Несколько телефонов, адресов или меток разделяйте запятой. Изменённые поля будут сохранены как ручные.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Button("Отмена", role: .cancel) { dismiss() }.disabled(submitting); Spacer()
                Button("Сохранить") {
                    let draft = ContactDraft(displayName: name, organization: organization, jobTitle: job, phones: split(phones), emails: split(emails), tags: split(tags))
                    guard model.canWrite, !submitting else { return }
                    submitting = true
                    Task {
                        defer { submitting = false }
                        if await model.save(draft, id: contact?.id) { dismiss() }
                        else { error = model.error; model.error = nil }
                    }
                }.buttonStyle(.borderedProminent).disabled(!model.canWrite || submitting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("editor.save")
            }
        }.padding(28).frame(width: 510).interactiveDismissDisabled(submitting)
    }
    private func split(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
}
