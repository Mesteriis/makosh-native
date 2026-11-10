import MakoshJira
import MakoshTasks
import SwiftUI

/// The Jira half of the card: status with the transitions Jira allows, the
/// assignee with «Передать…», editable fields where Jira lets Makosh edit
/// them, comments with a reply field, the user's worklogs, and every
/// attempt with its state.
struct JiraIssueCard: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    let observation: TaskProviderObservation
    let connection: JiraConnection
    @State private var transition: JiraTransition?
    @State private var assigning = false
    @State private var editing = false
    @State private var reply = ""

    private var issue: JiraIssue { observation.issue }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(issue.key).font(.headline.monospaced())
                Text(issue.status.name).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(
                    Color.accentColor.opacity(0.2), in: Capsule())
                Spacer()
                Link("Открыть в Jira", destination: issue.browseURL).font(.caption).accessibilityIdentifier("tasks.jira.open")
            }
            Text(issue.summary).font(.body.bold()).textSelection(.enabled)
            transitions
            people
            fields
            description
            comments
            worklogs
            attempts
            HStack {
                Text("Проверено \(observation.observedAt.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(
                    .secondary)
                Spacer()
                Button("Обновить") { _Concurrency.Task { await model.refreshIssue(id: task.id) } }.controlSize(.small)
                    .accessibilityIdentifier("tasks.jira.refresh")
            }
        }
        .sheet(item: $transition) { value in JiraTransitionSheet(model: model, task: task, transition: value).makoshAppearance() }
        .sheet(isPresented: $assigning) { JiraAssignSheet(model: model, task: task, current: issue.assignee).makoshAppearance() }
        .sheet(isPresented: $editing) {
            JiraFieldsSheet(model: model, task: task, issue: issue, priorities: model.priorities[connection.id] ?? []).makoshAppearance()
        }
    }

    private var transitions: some View {
        Group {
            if observation.transitions.isEmpty {
                Button("Показать переходы") { _Concurrency.Task { await model.refreshIssue(id: task.id) } }.controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Переход").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(observation.transitions) { value in
                            let blocked = model.blockedFields(value)
                            Button {
                                if blocked.isEmpty, model.transitionRequirements(value).isEmpty {
                                    _Concurrency.Task { await model.jira(.transition(value, fields: [:]), id: task.id) }
                                } else {
                                    transition = value
                                }
                            } label: {
                                Label(value.name, systemImage: blocked.isEmpty ? "arrow.right" : "lock")
                            }
                            .controlSize(.small).help(blocked.isEmpty ? "→ \(value.to.name)" : "Поля заполняются только в Jira")
                            .accessibilityIdentifier("tasks.jira.transition.\(value.id)")
                        }
                    }
                }
            }
        }
    }

    private var people: some View {
        HStack(spacing: 12) {
            Label(issue.assignee?.displayName ?? "не назначена", systemImage: "person").font(.caption)
            Button("Передать…") { assigning = true }.controlSize(.small).accessibilityIdentifier("tasks.jira.assign")
            Spacer()
            if let reporter = issue.reporter { Text("от \(reporter.displayName)").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var fields: some View {
        HStack(spacing: 12) {
            if let priority = issue.priority { Label(priority.name, systemImage: "flag").font(.caption) }
            if let due = issue.due { Label(TaskStyle.day(due), systemImage: "calendar").font(.caption) }
            ForEach(issue.labels, id: \.self) {
                Text($0).font(.caption).padding(.horizontal, 5).background(.white.opacity(0.08), in: Capsule())
            }
            Spacer()
            Button("Изменить…") { editing = true }.controlSize(.small).accessibilityIdentifier("tasks.jira.edit")
        }
    }

    private var description: some View {
        Group {
            if !issue.descriptionText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Описание").font(.caption).foregroundStyle(.secondary)
                        if !model.canEditDescription(id: task.id) {
                            Text("· с таблицами или вложениями, правится в Jira").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Text(issue.descriptionText).font(.callout).textSelection(.enabled).lineLimit(16)
                }
            }
            if task.source?.membership == .mentioned {
                Label("Вас упомянули в комментариях", systemImage: "at").font(.caption).foregroundStyle(.orange)
            }
            if task.source?.membership == TaskMembership.none {
                Label(
                    "Перестала быть вашей · не обновляется с \(observation.observedAt.formatted(date: .abbreviated, time: .shortened))",
                    systemImage: "clock"
                )
                .font(.caption).foregroundStyle(.orange)
                Button("Оставить в «Моих»") { _Concurrency.Task { await model.keep(id: task.id) } }.controlSize(.small)
            }
        }
    }

    private var comments: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Комментарии").font(.caption).foregroundStyle(.secondary)
            ForEach(observation.comments.suffix(20)) { comment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(comment.author.displayName).font(.caption.bold())
                        Text(comment.created.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(comment.bodyText).font(.callout).textSelection(.enabled)
                }.accessibilityIdentifier("tasks.jira.comment.\(comment.id)")
            }
            HStack(alignment: .bottom) {
                TextField("Ответить… (⌘↩ отправить)", text: $reply, axis: .vertical).lineLimit(1...4).textFieldStyle(
                    WorkspaceTextFieldStyle()
                )
                .accessibilityIdentifier("tasks.jira.reply")
                Button("Отправить") { send() }.keyboardShortcut(.return, modifiers: .command).controlSize(.small)
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier(
                        "tasks.jira.reply.send")
            }
        }
    }

    private func send() {
        let text = reply
        reply = ""
        _Concurrency.Task { await model.jira(.comment(text), id: task.id) }
    }

    private var worklogs: some View {
        Group {
            if !observation.myWorklogs.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Мои worklog в Jira").font(.caption).foregroundStyle(.secondary)
                    ForEach(observation.myWorklogs) { worklog in
                        HStack {
                            Text(worklog.started.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            Text(TaskStyle.duration(worklog.seconds)).font(.caption.bold())
                            Text(worklog.commentText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var attempts: some View {
        Group {
            let rows = model.attempts(id: task.id).suffix(5)
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Отправки").font(.caption).foregroundStyle(.secondary)
                    ForEach(rows) { attempt in JiraAttemptRow(model: model, attempt: attempt) }
                }
            }
        }
    }
}

/// One attempt and its state; unknown ones offer «Проверить» and «Отказаться».
struct JiraAttemptRow: View {
    @ObservedObject var model: TasksWorkspaceModel
    let attempt: TaskJiraAttempt

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(attempt.title).font(.caption)
            Text(state).font(.caption).foregroundStyle(color).lineLimit(1)
            Spacer()
            if attempt.state == .unknown {
                Button("Проверить") { _Concurrency.Task { await model.resolveAttempt(id: attempt.id) } }.controlSize(.small)
                    .accessibilityIdentifier("tasks.attempt.resolve.\(attempt.id.uuidString)")
                Button("Отказаться") { _Concurrency.Task { await model.dismissAttempt(id: attempt.id) } }.controlSize(.small)
                    .accessibilityIdentifier("tasks.attempt.dismiss.\(attempt.id.uuidString)")
            }
        }.accessibilityIdentifier("tasks.attempt.\(attempt.id.uuidString)")
    }

    private var symbol: String {
        switch attempt.state {
        case .queued, .sent: "clock"
        case .unknown: "questionmark.circle"
        case .confirmed: "checkmark.circle"
        case .rejected: "xmark.circle"
        }
    }
    private var color: Color {
        switch attempt.state {
        case .queued, .sent: .secondary
        case .unknown: .orange
        case .confirmed: .green
        case .rejected: .red
        }
    }
    private var state: String {
        switch attempt.state {
        case .queued, .sent: "Отправляется"
        case .unknown: "Неизвестно" + (attempt.reason.map { " · \($0)" } ?? "")
        case .confirmed: "Принято"
        case .rejected: "Отклонено" + (attempt.reason.map { ": \($0)" } ?? "")
        }
    }
}

/// Fields a transition screen asks for; unsupported required ones block the send.
struct JiraTransitionSheet: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    let transition: JiraTransition
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: JiraFieldValue] = [:]
    @State private var texts: [String: String] = [:]

    private var blocked: [JiraField] { model.blockedFields(transition) }
    private var required: [JiraField] { model.transitionRequirements(transition) }
    private var optional: [JiraField] { transition.fields.filter { !$0.required && JiraFieldSupport.isSupported($0) } }
    private var complete: Bool { blocked.isEmpty && required.allSatisfy { values[$0.key] != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(transition.name) → \(transition.to.name)").font(.headline)
            ForEach(blocked, id: \.key) { field in
                HStack {
                    Label(field.name, systemImage: "lock").foregroundStyle(.orange)
                    Spacer()
                    Text("заполняется только в Jira").font(.caption).foregroundStyle(.orange)
                }
            }
            if !blocked.isEmpty, let url = model.observation(id: task.id)?.issue.browseURL {
                Link("Открыть в Jira", destination: url).font(.caption)
            }
            ForEach(required + optional, id: \.key) { field in row(field) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Выполнить") {
                    let fields = values
                    dismiss()
                    _Concurrency.Task { await model.jira(.transition(transition, fields: fields), id: task.id) }
                }.keyboardShortcut(.defaultAction).disabled(!complete).accessibilityIdentifier("tasks.jira.transition.send")
            }
        }.padding(16).frame(width: 440)
    }

    @ViewBuilder private func row(_ field: JiraField) -> some View {
        let title = field.name + (field.required ? " *" : "")
        switch field.schemaType {
        case "option", "resolution":
            MakoshPicker(
                title,
                selection: Binding(
                    get: { values[field.key]?.optionID ?? "" },
                    set: { id in
                        values[field.key] = id.isEmpty ? nil : (field.schemaType == "resolution" ? .resolution(id: id) : .option(id: id))
                    })
            ) {
                Text("—").tag("")
                ForEach(field.allowedValues ?? [], id: \.id) { Text($0.name).tag($0.id) }
            }.accessibilityIdentifier("tasks.jira.field.\(field.key)")
        case "number":
            TextField(
                title,
                text: Binding(
                    get: { texts[field.key] ?? "" },
                    set: { text in
                        texts[field.key] = text
                        values[field.key] = Double(text.replacingOccurrences(of: ",", with: ".")).map { .number($0) }
                    })
            ).textFieldStyle(WorkspaceTextFieldStyle()).accessibilityIdentifier("tasks.jira.field.\(field.key)")
        case "date":
            DatePicker(
                title, selection: Binding(get: { values[field.key]?.date ?? Date() }, set: { values[field.key] = .date($0) }),
                displayedComponents: .date
            )
            .accessibilityIdentifier("tasks.jira.field.\(field.key)")
        default:
            TextField(
                title,
                text: Binding(
                    get: { texts[field.key] ?? "" },
                    set: { text in
                        texts[field.key] = text
                        values[field.key] = text.isEmpty ? nil : .text(text)
                    }), axis: .vertical
            ).lineLimit(1...4).textFieldStyle(WorkspaceTextFieldStyle()).accessibilityIdentifier("tasks.jira.field.\(field.key)")
        }
    }
}

extension JiraFieldValue {
    var optionID: String? {
        switch self {
        case .option(let id), .resolution(let id): id
        default: nil
        }
    }
    var date: Date? { if case .date(let value) = self { value } else { nil } }
}

/// Hand the issue to someone: search the project's assignable users.
struct JiraAssignSheet: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    let current: JiraUser?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var users: [JiraUser] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Передать задачу").font(.headline)
            Text("Сейчас: \(current?.displayName ?? "не назначена")").font(.caption).foregroundStyle(.secondary)
            TextField("Имя (от 2 символов)", text: $query).textFieldStyle(WorkspaceTextFieldStyle()).accessibilityIdentifier(
                "tasks.jira.assign.query"
            )
            .onChange(of: query) { _, value in search(value) }
            List(users, id: \.accountID) { user in
                Button(user.displayName) { assign(user.accountID) }.buttonStyle(.plain).accessibilityIdentifier(
                    "tasks.jira.assign.\(user.accountID)")
            }.frame(minHeight: 160)
            HStack {
                Button("Снять назначение") { assign(nil) }.disabled(current == nil).accessibilityIdentifier("tasks.jira.assign.none")
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(16).frame(width: 400)
    }

    private func search(_ text: String) {
        guard text.count >= 2 else {
            users = []
            return
        }
        searching = true
        _Concurrency.Task {
            let found = await model.assignableUsers(id: task.id, query: text)
            if query == text {
                users = found
                searching = false
            }
        }
    }

    private func assign(_ accountID: String?) {
        dismiss()
        _Concurrency.Task { await model.jira(.assign(accountID: accountID), id: task.id) }
    }
}

/// Summary, priority, due date, labels and (when simple) the description.
struct JiraFieldsSheet: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    let issue: JiraIssue
    let priorities: [JiraPriority]
    @Environment(\.dismiss) private var dismiss
    @State private var summary = ""
    @State private var priorityID = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var labels = ""
    @State private var descriptionText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Изменить \(issue.key)").font(.headline)
            TextField("Название", text: $summary).textFieldStyle(WorkspaceTextFieldStyle()).accessibilityIdentifier(
                "tasks.jira.fields.summary")
            if !priorities.isEmpty {
                MakoshPicker("Приоритет", selection: $priorityID) {
                    Text("—").tag("")
                    ForEach(priorities, id: \.id) { Text($0.name).tag($0.id) }
                }.accessibilityIdentifier("tasks.jira.fields.priority")
            }
            HStack {
                Toggle("Срок", isOn: $hasDue)
                if hasDue { DatePicker("", selection: $due, displayedComponents: .date).labelsHidden() }
            }
            TextField("Метки через запятую", text: $labels).textFieldStyle(WorkspaceTextFieldStyle()).accessibilityIdentifier(
                "tasks.jira.fields.labels")
            if model.canEditDescription(id: task.id) {
                Text("Описание").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $descriptionText).workspaceEditorSurface().frame(minHeight: 120).accessibilityIdentifier(
                    "tasks.jira.fields.description")
            } else {
                Label("Описание с таблицами или вложениями правится только в Jira.", systemImage: "lock").font(.caption).foregroundStyle(
                    .orange)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { save() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("tasks.jira.fields.save")
            }
        }
        .padding(16).frame(width: 480)
        .onAppear {
            summary = issue.summary
            priorityID = issue.priority?.id ?? ""
            hasDue = issue.due != nil
            due = issue.due ?? Date()
            labels = issue.labels.joined(separator: ", ")
            descriptionText = issue.descriptionText
        }
    }

    private func save() {
        var patch = JiraIssuePatch()
        if summary != issue.summary { patch.summary = summary }
        if priorityID != (issue.priority?.id ?? ""), !priorityID.isEmpty { patch.priorityID = priorityID }
        let newLabels = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if newLabels != issue.labels { patch.labels = newLabels }
        if hasDue != (issue.due != nil) || (hasDue && issue.due.map({ !Calendar.current.isDate($0, inSameDayAs: due) }) == true) {
            patch.due = .some(hasDue ? due : nil)
        }
        if model.canEditDescription(id: task.id), descriptionText != issue.descriptionText {
            patch.descriptionADF = JiraADF.document(fromText: descriptionText)
        }
        dismiss()
        guard !patch.isEmpty else { return }
        _Concurrency.Task { await model.jira(.fields(patch), id: task.id) }
    }
}

/// Wraps buttons onto new lines when the column is narrow.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
