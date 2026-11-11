import MakoshCore
import SwiftUI

/// The create/edit sheet: a kind on creation, the structured name for people, then the
/// lists. Values typed here are manual; sources add beside them and never remove them.
struct PersonEditor: View {
    let contact: Person?
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    private let kind: PersonKind
    @State private var name: String
    @State private var givenName: String
    @State private var familyName: String
    @State private var middleName: String
    @State private var organization: String
    @State private var job: String
    @State private var phones: String
    @State private var emails: String
    @State private var usernames: String
    @State private var tags: String
    @State private var error: String?
    @State private var submitting = false

    init(contact: Person?, kind: PersonKind = .person, model: WorkspaceModel) {
        self.contact = contact
        self.kind = contact?.kind ?? kind
        self.model = model
        _name = State(initialValue: contact?.displayName ?? "")
        _givenName = State(initialValue: contact?.givenName ?? "")
        _familyName = State(initialValue: contact?.familyName ?? "")
        _middleName = State(initialValue: contact?.middleName ?? "")
        _organization = State(initialValue: contact?.organization ?? "")
        _job = State(initialValue: contact?.jobTitle ?? "")
        _phones = State(initialValue: contact?.phones.joined(separator: ", ") ?? "")
        _emails = State(initialValue: contact?.emails.joined(separator: ", ") ?? "")
        _usernames = State(initialValue: contact?.usernames.joined(separator: ", ") ?? "")
        _tags = State(initialValue: contact?.tags.joined(separator: ", ") ?? "")
    }

    private var title: String {
        if contact != nil { return kind == .organization ? "Изменить организацию" : "Изменить персону" }
        return kind == .organization ? "Новая организация" : "Новая персона"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title2.bold())
            Form {
                let displayTitle = kind == .organization ? "Название" : "Имя (как показывать)"
                WorkspaceLabeledField(displayTitle) { TextField(displayTitle, text: $name).accessibilityIdentifier("editor.name") }
                if kind == .person {
                    WorkspaceLabeledField("Имя") { TextField("Имя", text: $givenName).accessibilityIdentifier("editor.givenName") }
                    WorkspaceLabeledField("Фамилия") {
                        TextField("Фамилия", text: $familyName).accessibilityIdentifier("editor.familyName")
                    }
                    WorkspaceLabeledField("Отчество") { TextField("Отчество", text: $middleName) }
                    WorkspaceLabeledField("Компания") {
                        TextField("Компания", text: $organization).accessibilityIdentifier("editor.organization")
                    }
                    WorkspaceLabeledField("Должность") { TextField("Должность", text: $job) }
                }
                WorkspaceLabeledField("Телефоны") { TextField("Телефоны", text: $phones) }
                WorkspaceLabeledField("Почта") { TextField("Почта", text: $emails).accessibilityIdentifier("editor.email") }
                if kind == .person { WorkspaceLabeledField("Имена пользователя") { TextField("Имена пользователя", text: $usernames) } }
                WorkspaceLabeledField("Метки") { TextField("Метки", text: $tags) }
            }
            Text(
                "Несколько значений разделяйте запятой. Введённые значения будут ручными: источники добавят свои рядом, но не уберут ваши."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            HStack {
                Button("Отмена", role: .cancel) { dismiss() }.disabled(submitting)
                Spacer()
                Button("Сохранить") {
                    let draft = PersonDraft(
                        kind: kind, displayName: name, givenName: givenName, familyName: familyName, middleName: middleName,
                        organization: organization, jobTitle: job, phones: split(phones), emails: split(emails),
                        usernames: split(usernames),
                        tags: split(tags))
                    guard model.canWrite, !submitting else { return }
                    submitting = true
                    Task {
                        defer { submitting = false }
                        if await model.save(draft, id: contact?.id) {
                            dismiss()
                        } else {
                            error = model.error
                            model.error = nil
                        }
                    }
                }.buttonStyle(WorkspaceButtonStyle(prominent: true)).disabled(
                    !model.canWrite || submitting || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ).accessibilityIdentifier("editor.save")
            }
        }.padding(28).frame(width: 540).interactiveDismissDisabled(submitting)
    }

    private func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// Picks one person (or one organization) by name: for «Склеить с…» and «Добавить в организацию…».
struct PersonPicker: View {
    let title: String
    let kind: PersonKind
    let exclude: UUID?
    @ObservedObject var workspace: WorkspaceModel
    let onPick: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    static func candidates(summaries: [PersonSummary], kind: PersonKind, exclude: UUID?, query: String) -> [PersonSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return summaries.filter { summary in
            summary.kind == kind && summary.isActive && summary.id != exclude
                && (needle.isEmpty || summary.displayName.localizedCaseInsensitiveContains(needle)
                    || summary.organization.localizedCaseInsensitiveContains(needle))
        }
    }

    private var candidates: [PersonSummary] {
        Self.candidates(summaries: workspace.persons.map(\.summary), kind: kind, exclude: exclude, query: query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.bold())
            TextField("Поиск по имени", text: $query).textFieldStyle(WorkspaceTextFieldStyle()).accessibilityIdentifier(
                "persons.picker.search")
            List(candidates) { summary in
                Button {
                    onPick(summary.id)
                    dismiss()
                } label: {
                    HStack {
                        PersonsAvatar(name: summary.displayName, size: 28)
                        VStack(alignment: .leading) {
                            Text(summary.displayName)
                            if !summary.organization.isEmpty { Text(summary.organization).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("persons.picker.\(summary.id)")
            }.listStyle(.inset)
            if candidates.isEmpty { Text("Ничего не найдено.").foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
            }
        }.padding(24).frame(width: 440, height: 480)
    }
}
