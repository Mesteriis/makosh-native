import MakoshCore
import MakoshOSINT
import MakoshPersons
import SwiftUI

/// The flag and the state of every book-receiving account for this person.
struct PersonAddressBookSection: View {
    let person: Person
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var host: PersonsHost
    @State private var confirmDelete = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(
                    "Адресная книга",
                    isOn: Binding(
                        get: { person.addressBook },
                        set: { value in
                            Task {
                                _ = await workspace.setAddressBook(value, personID: person.id)
                                await host.model?.refresh()
                            }
                        })
                ).toggleStyle(WorkspaceToggleStyle()).disabled(!workspace.canWrite || person.hiddenAsSpam).accessibilityIdentifier(
                    "person.addressBook")
                if person.hiddenAsSpam {
                    Text("Персона скрыта как спам: в адресную книгу не попадает.").font(.caption).foregroundStyle(.orange)
                } else if let origin = person.addressBookOrigin, case .sourceAccount(let source) = origin {
                    Text("Признак поставлен учётной записью \(source.service).").font(.caption).foregroundStyle(.secondary)
                }
                if let model = host.model {
                    let rows = model.bookStates(for: person.id)
                    if rows.isEmpty {
                        Text("Книги-получатели не подключены.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(rows, id: \.book.id) { row in bookRow(row, model: model) }
                    let duplicates = model.snapshot?.entries.filter { $0.personID == person.id && $0.state == .duplicate } ?? []
                    ForEach(duplicates) { entry in
                        HStack {
                            Label(
                                "Дубль в книге \(model.snapshot?.books.first { $0.id == entry.bookID }?.name ?? "")",
                                systemImage: "doc.on.doc"
                            )
                            .font(.caption)
                            Spacer()
                            Button("Удалить дубль") { Task { await model.deleteDuplicate(entryID: entry.id) } }.font(.caption)
                        }
                    }
                    if person.addressBook, !rows.isEmpty {
                        Button("Удалить везде…", role: .destructive) { confirmDelete = true }.accessibilityIdentifier(
                            "person.deleteEverywhere"
                        )
                        .confirmationDialog(
                            "Удалить карточку из внешних книг?", isPresented: $confirmDelete, titleVisibility: .visible
                        ) {
                            Button(
                                "Удалить из: \(rows.filter { $0.entry != nil }.map(\.book.name).joined(separator: ", "))",
                                role: .destructive
                            ) {
                                Task { await model.deleteEverywhere(personID: person.id) }
                            }
                            Button("Отмена", role: .cancel) {}
                        } message: {
                            Text("Карточки удалятся только из книг, которые ведёт Makosh. Персона в Makosh останется.")
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
            Label("Адресная книга", systemImage: "book.closed")
        }
    }

    @ViewBuilder private func bookRow(_ row: PersonBookRow, model: PersonsWorkspaceModel) -> some View {
        HStack(spacing: 8) {
            Text(row.book.name).font(.callout)
            Spacer()
            if let attempt = row.attempt {
                switch attempt.state {
                case .unknown:
                    Text("неизвестно").font(.caption).foregroundStyle(.orange)
                    Button("Проверить") { Task { await model.settle(bookID: row.book.id) } }.font(.caption)
                    Button("Отказаться") { Task { await model.dismiss(attemptID: attempt.id) } }.font(.caption)
                default: Text("отправляется…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let blocked = row.blocked {
                Text(PersonsWorkspaceModel.describe(blocked)).font(.caption).foregroundStyle(.orange)
            } else if let entry = row.entry {
                switch entry.state {
                case .managed: Label("в книге", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                case .notManaged:
                    Text("удалена снаружи").font(.caption).foregroundStyle(.secondary)
                    Button("Отправить снова") { Task { await model.resend(entryID: entry.id) } }.font(.caption)
                case .duplicate: Text("дубль").font(.caption).foregroundStyle(.secondary)
                case .removed: Text("удалена").font(.caption).foregroundStyle(.secondary)
                }
            } else if person.addressBook {
                Text("ожидает записи").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("—").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Phones, addresses and usernames with their provenance; former values struck through.
struct PersonContactsSection: View {
    let person: Person
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var host: PersonsHost
    @State private var mailCounts: [String: Int] = [:]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(person.emails, id: \.self) { value in row(value, field: .emails, symbol: "envelope") }
                ForEach(person.phones, id: \.self) { value in row(value, field: .phones, symbol: "phone") }
                ForEach(person.usernames, id: \.self) { value in row(value, field: .usernames, symbol: "at") }
                if person.emails.isEmpty && person.phones.isEmpty && person.usernames.isEmpty {
                    Text("Почта и телефон пока не указаны").foregroundStyle(.secondary)
                }
                let former = person.former.filter { $0.field != PersonListField.tags.rawValue }
                if !former.isEmpty {
                    Divider()
                    ForEach(Array(former.enumerated()), id: \.offset) { _, value in
                        HStack(spacing: 8) {
                            Text(value.value).strikethrough().foregroundStyle(.secondary).textSelection(.enabled)
                            Text("прежний · с \(value.since.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(
                                .secondary)
                            Spacer()
                            if let field = PersonListField(rawValue: value.field) {
                                Button("Вернуть") {
                                    Task { _ = await workspace.restoreValue(value.value, field: field, personID: person.id) }
                                }
                                .font(.caption).disabled(!workspace.canWrite)
                            }
                        }
                    }
                }
                let proposed = person.observations.filter {
                    $0.status == .proposed && $0.source.identity.service != OSINTGraphMapping.service
                }
                ForEach(proposed) { observation in
                    HStack(spacing: 8) {
                        Label("\(observation.value)", systemImage: "sparkles").font(.callout)
                        Text("предложено ИИ").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Принять") { Task { _ = await workspace.confirmObservation(observation.id, personID: person.id) } }.font(
                            .caption)
                        Button("Отклонить") { Task { _ = await workspace.rejectObservation(observation.id, personID: person.id) } }.font(
                            .caption)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
            Label("Как связаться", systemImage: "person.crop.circle")
        }
        .task(id: person.emails) {
            guard let model = host.model else { return }
            var counts: [String: Int] = [:]
            for address in person.emails { counts[address] = await model.mailCount(address: address) }
            mailCounts = counts
        }
    }

    private func row(_ value: String, field: PersonListField, symbol: String) -> some View {
        HStack(spacing: 8) {
            Label(value, systemImage: symbol).textSelection(.enabled)
            Text(source(value, field: field)).font(.caption).foregroundStyle(.secondary)
            if field == .emails, let count = mailCounts[value], count > 0 {
                Text("· писем: \(count)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Убрать", role: .destructive) { Task { _ = await workspace.removeValue(value, field: field, personID: person.id) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }.menuStyle(.borderlessButton).fixedSize().disabled(!workspace.canWrite).accessibilityIdentifier("person.value.\(value)")
        }
    }

    private func source(_ value: String, field: PersonListField) -> String {
        if person.manualValues.contains(ManualValue(field: field.rawValue, value: value)) { return "вручную" }
        let services = Set(person.observations.filter { $0.field == field.rawValue && $0.value == value }.map(\.source.identity.service))
        return services.sorted().map(PersonCardText.service).joined(separator: ", ")
    }
}

/// Memberships of a person with their origin; accept or remove suggestions; add by hand.
struct PersonOrganizationsSection: View {
    let person: Person
    @ObservedObject var workspace: WorkspaceModel
    @State private var picking = false

    private var memberships: [PersonMembership] { workspace.memberships.filter { $0.personID == person.id } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if memberships.isEmpty { Text("Не состоит в организациях").foregroundStyle(.secondary) }
                ForEach(memberships) { membership in
                    HStack(spacing: 8) {
                        Button {
                            workspace.selectedID = membership.organizationID
                        } label: {
                            Text(workspace.name(membership.organizationID)).font(.callout.weight(.semibold))
                        }.buttonStyle(.plain)
                        if !membership.role.isEmpty { Text("— " + membership.role).font(.callout) }
                        Text(PersonCardText.origin(membership)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if membership.state == .suggested {
                            Button("Принять") { Task { _ = await workspace.setMembershipState(.confirmed, id: membership.id) } }.font(
                                .caption)
                            Button("Снять") { Task { _ = await workspace.setMembershipState(.removed, id: membership.id) } }.font(.caption)
                        } else {
                            Button("Убрать") { Task { _ = await workspace.setMembershipState(.removed, id: membership.id) } }.font(.caption)
                        }
                    }
                }
                Button("Добавить в организацию…") { picking = true }.disabled(!workspace.canWrite).accessibilityIdentifier(
                    "person.addOrganization")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
            Label("Организации", systemImage: "building.2")
        }
        .sheet(isPresented: $picking) {
            PersonPicker(title: "В какую организацию?", kind: .organization, exclude: nil, workspace: workspace) { organizationID in
                Task { _ = await workspace.addToOrganization(personID: person.id, organizationID: organizationID) }
            }.makoshAppearance()
        }
    }
}

/// The people of an organization, with their roles.
struct OrganizationMembersSection: View {
    let organization: Person
    @ObservedObject var workspace: WorkspaceModel
    @State private var picking = false

    private var members: [PersonMembership] { workspace.memberships.filter { $0.organizationID == organization.id } }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if members.isEmpty { Text("Пока никого").foregroundStyle(.secondary) }
                ForEach(members) { membership in
                    HStack(spacing: 10) {
                        PersonsAvatar(name: workspace.name(membership.personID), size: 28)
                        Button {
                            workspace.selectedID = membership.personID
                        } label: {
                            Text(workspace.name(membership.personID)).font(.callout.weight(.semibold))
                        }.buttonStyle(.plain)
                        if !membership.role.isEmpty { Text(membership.role).font(.callout).foregroundStyle(.secondary) }
                        if membership.state == .suggested { Text("предложено").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Убрать") { Task { _ = await workspace.setMembershipState(.removed, id: membership.id) } }.font(.caption)
                    }
                }
                Button("Добавить человека…") { picking = true }.disabled(!workspace.canWrite).accessibilityIdentifier(
                    "organization.addMember")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
            Label("Люди · \(members.count)", systemImage: "person.2")
        }
        .sheet(isPresented: $picking) {
            PersonPicker(title: "Кого добавить?", kind: .person, exclude: nil, workspace: workspace) { personID in
                Task { _ = await workspace.addToOrganization(personID: personID, organizationID: organization.id) }
            }.makoshAppearance()
        }
    }
}

enum PersonCardText {
    static func service(_ service: String) -> String {
        switch service {
        case "manual": "вручную"
        case "mail": "почта"
        case "telegram": "Telegram"
        case "whatsapp": "WhatsApp"
        case "teams": "Teams"
        case "carddav": "CardDAV"
        case "google-contacts": "Google"
        case "macos-contacts": "Контакты macOS"
        case "ai": "ИИ"
        case "osint": "OSINT"
        default: service
        }
    }
    static func origin(_ membership: PersonMembership) -> String {
        switch membership.origin {
        case .manual: "вручную"
        case .companyField: "по полю «компания»"
        case .emailDomain(let domain): "по домену \(domain)"
        case .ai: "предложено ИИ"
        }
    }
    static func field(_ field: String) -> String {
        [
            "displayName": "Имя", "givenName": "Имя (личное)", "familyName": "Фамилия", "middleName": "Отчество",
            "organization": "Компания",
            "jobTitle": "Должность", "phones": "Телефон", "emails": "Почта", "usernames": "Имя пользователя", "tags": "Метки",
        ][field] ?? field
    }
}
