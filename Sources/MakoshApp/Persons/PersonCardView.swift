import MakoshCore
import MakoshOSINT
import MakoshPersons
import MakoshTelemost
import SwiftUI

/// The full dossier of a person or an organization: the address-book flag and book states,
/// contacts with provenance, organizations (or members), AI access, notes, sources, history.
struct PersonCardView: View {
    @EnvironmentObject private var ai: AIHost
    let contact: Person
    @ObservedObject var model: WorkspaceModel
    @ObservedObject var host: PersonsHost
    var openMeeting: (String) -> Void = { _ in }
    let edit: () -> Void
    @State private var note = ""
    @State private var noteSubmitting = false
    @State private var merging = false
    @State private var detaching: ServiceIdentity?
    @State private var confirmDelete = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(contact.kind == .organization ? "ОРГАНИЗАЦИЯ" : "ДОСЬЕ ПЕРСОНЫ").font(.caption.weight(.semibold)).tracking(1.5)
                            .foregroundStyle(.secondary)
                        Text(contact.displayName).font(.system(size: 30, weight: .semibold))
                        Text([contact.jobTitle, contact.organization].filter { !$0.isEmpty }.joined(separator: " · ")).foregroundStyle(
                            .secondary)
                        if contact.deletedAt != nil { Text("Удалена").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    if contact.deletedAt != nil {
                        Button("Восстановить") { Task { _ = await model.restorePerson(contact.id) } }.accessibilityIdentifier(
                            "person.restore")
                    } else {
                        Button("Изменить", action: edit).disabled(!model.canWrite).accessibilityIdentifier("contact.edit")
                        Menu {
                            Button("Склеить с…") { merging = true }.accessibilityIdentifier("person.merge")
                            Button("Удалить", role: .destructive) { confirmDelete = true }.accessibilityIdentifier("person.delete")
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }.menuStyle(.borderlessButton).fixedSize().disabled(!model.canWrite)
                    }
                }
                if !contact.tags.isEmpty {
                    Text(contact.tags.map { "#" + $0 }.joined(separator: "   ")).font(.callout).foregroundStyle(WorkspaceStyle.accent)
                }
                PersonAddressBookSection(person: contact, workspace: model, host: host)
                PersonContactsSection(person: contact, workspace: model, host: host)
                if contact.kind == .organization {
                    OrganizationMembersSection(organization: contact, workspace: model)
                } else {
                    PersonOrganizationsSection(person: contact, workspace: model)
                }
                if let osint = host.osintModel {
                    PersonOSINTSection(person: contact, workspace: model, osint: osint) { merging = true }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(
                            "Доступ для ИИ",
                            selection: Binding(
                                get: { contact.aiAccess },
                                set: { value in
                                    Task {
                                        if await model.setAIAccess(value, contactID: contact.id) { await ai.contactAccessChanged() }
                                    }
                                })
                        ) {
                            Text("Как у чата").tag(AIContactAccess.inherit)
                            Text("Разрешено").tag(AIContactAccess.allowed)
                            Text("Запрещено").tag(AIContactAccess.forbidden)
                        }
                        .pickerStyle(.segmented).disabled(!model.canWrite).accessibilityIdentifier("contact.aiAccess")
                        Text(
                            "«Запрещено» закрывает сообщения этого человека для ИИ во всех чатах и ящиках. «Разрешено» не открывает выключенный чат."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                } label: {
                    Label("ИИ", systemImage: "sparkles")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Заметки").font(.title3.weight(.semibold))
                    if contact.notes.isEmpty { Text("Контекст, который важно сохранить.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(contact.notes) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.text).textSelection(.enabled)
                            if item.source.identity.service == "telemost",
                                let link = item.text.split(separator: "\n").compactMap({ try? TelemostMeetingURL(String($0)) }).first,
                                link.conferenceID.utf8.elementsEqual(item.source.identity.externalID.utf8)
                            {
                                Button("Открыть встречу Телемоста") { openMeeting(link.url.absoluteString) }
                            }
                            Text(
                                "\(item.source.identity.service) · \(item.source.identity.accountID) · \(item.source.fetchedAt.formatted(date: .abbreviated, time: .shortened))"
                            ).font(.caption).foregroundStyle(.secondary)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                            .quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    }
                    TextField("Новая заметка", text: $note, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("contact.note")
                    HStack {
                        Spacer()
                        Button("Добавить заметку") {
                            guard model.canWrite, !noteSubmitting else { return }
                            let text = note, id = contact.id
                            noteSubmitting = true
                            Task {
                                defer { noteSubmitting = false }
                                if await model.addNote(text, contactID: id), note == text, model.selectedID == id { note = "" }
                            }
                        }.disabled(!model.canWrite || noteSubmitting || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("contact.note.add")
                    }
                }
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        if contact.identities.isEmpty { Text("Добавлен вручную на этом Mac").foregroundStyle(.secondary) }
                        ForEach(contact.identities) { identity in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(PersonCardText.service(identity.service)).font(.headline)
                                    Text("Аккаунт: \(identity.accountID)")
                                    Text("ID источника: \(identity.externalID)").font(.caption).textSelection(.enabled)
                                }
                                Spacer()
                                if identity.service != OSINTGraphMapping.service {
                                    Button("Отделить источник…") { detaching = identity }.font(.caption).disabled(!model.canWrite)
                                        .accessibilityIdentifier("person.detach.\(identity.id)")
                                }
                            }
                        }
                        ForEach(contact.observations) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(
                                    "\(PersonCardText.field(item.field)): \(item.value)" + (item.status == .proposed ? " · предложено" : "")
                                )
                                Text(
                                    "\(item.source.identity.service) · аккаунт \(item.source.identity.accountID) · запись \(item.source.identity.externalID) · \(item.source.fetchedAt.formatted())"
                                ).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Источники и аккаунты · \(contact.identities.count)", systemImage: "tray.full").font(.headline)
                }.accessibilityIdentifier("contact.sources")
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    Text("История").font(.title3.weight(.semibold))
                    ForEach(contact.events.reversed()) { event in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "clock").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.detail)
                                Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if contact.events.isEmpty { Text("Изменений пока нет").foregroundStyle(.secondary) }
                }
            }.padding(30).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }.background { WorkspaceBackdrop(intensity: 0.4) }.id(contact.id)
            .sheet(isPresented: $merging) {
                PersonPicker(title: "С кем склеить?", kind: contact.kind, exclude: contact.id, workspace: model) { other in
                    Task {
                        if let persons = host.model {
                            await persons.mergePersons(survivorID: contact.id, removedID: other)
                            await model.reload()
                        } else {
                            _ = await model.merge(
                                DuplicateCandidate(firstID: contact.id, secondID: other, reasons: []), survivor: contact.id)
                        }
                    }
                }.makoshAppearance()
            }
            .confirmationDialog(
                "Отделить источник в новую персону?", isPresented: Binding(get: { detaching != nil }, set: { if !$0 { detaching = nil } }),
                titleVisibility: .visible
            ) {
                Button("Отделить") {
                    guard let identity = detaching else { return }
                    detaching = nil
                    Task { _ = await model.detachIdentity(identity, personID: contact.id) }
                }
                Button("Отмена", role: .cancel) { detaching = nil }
            } message: {
                Text(
                    "Источник, его наблюдения и заметки уйдут в новую персону. Ручные поля и признак адресной книги останутся здесь; эту пару Makosh больше не склеит сам."
                )
            }
            .confirmationDialog("Удалить персону?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { Task { _ = await model.deletePerson(contact.id) } }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Персона уйдёт из списков, но останется в Makosh и во внешних книгах. Вернуть её можно из фильтра «Удалённые».")
            }
    }
}
