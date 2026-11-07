import AppKit
import MakoshTasks
import SwiftUI

/// The reference's edit dialog: every field at once, chips for tags,
/// personas and dependencies, the notes list, and the `to:КОД` reference.
struct TaskEditDialog: View {
    @ObservedObject var model: TasksWorkspaceModel
    let task: Task
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var status: TaskStatus = .inbox
    @State private var priority = 4
    @State private var list = ""
    @State private var tags: [String] = []
    @State private var personas: [String] = []
    @State private var due = ""
    @State private var start = ""
    @State private var recurrence = ""
    @State private var url = ""
    @State private var estimate = ""
    @State private var flow = ""
    @State private var dependsOn: [UUID] = []
    @State private var notes: [TaskNote] = []
    @State private var newNote = ""
    @State private var editingNote: UUID?
    @State private var noteDraft = ""
    @State private var copied = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Правка задачи").font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.borderless)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Название") {
                        TextField("", text: $title).textFieldStyle(.roundedBorder).accessibilityIdentifier("tasks.edit.title")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("Статус") {
                            Picker("", selection: $status) {
                                ForEach(TaskStatus.allCases, id: \.self) { Text(TaskStyleText.status($0)).tag($0) }
                            }.labelsHidden()
                        }
                        field("Приоритет") {
                            HStack(spacing: 4) {
                                ForEach(1...4, id: \.self) { value in
                                    Button(String(value)) { priority = value }.buttonStyle(.plain).font(.caption.bold()).frame(
                                        maxWidth: .infinity
                                    ).padding(.vertical, 5)
                                        .background(
                                            priority == value ? TaskStyle.priority(value) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 5)
                                        )
                                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(TaskStyle.priority(value)))
                                        .foregroundStyle(priority == value ? Color.white : TaskStyle.priority(value))
                                }
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("Список") { TaskCombobox(text: $list, options: model.lists, placeholder: "новый список") }
                        field("Срок") { TaskDateField(text: $due, calendar: model.calendar) }
                    }
                    field("Теги") {
                        TaskChipsField(values: $tags, options: model.tags, kind: .tag, placeholder: "добавить тег", prefix: "#")
                    }
                    field("Персоны") {
                        TaskChipsField(
                            values: $personas, options: model.personas, kind: .persona, placeholder: "добавить персону", prefix: "/",
                            stripSpaces: true)
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("Дата начала") { TaskDateField(text: $start, calendar: model.calendar) }
                        field("Повтор") {
                            TaskCombobox(
                                text: $recurrence, options: TaskRecurrence.keywords + ["FREQ=WEEKLY;INTERVAL=2"],
                                placeholder: "daily / weekly / FREQ=…")
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        field("Ссылка") { TextField("https://…", text: $url).textFieldStyle(.roundedBorder) }
                        field("Оценка") { TextField("1 ч / 30 мин", text: $estimate).textFieldStyle(.roundedBorder) }
                    }
                    field("Цепочка") { TaskCombobox(text: $flow, options: model.flows, placeholder: "без цепочки") }
                    field("Зависит от") { dependencies }
                    notesEditor
                }.padding(20)
            }
            Divider()
            HStack {
                Button(copied ? "Скопировано" : TaskReference.text(code: task.code, title: "")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TaskReference.text(code: task.code, title: task.title), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }.buttonStyle(.plain).font(.caption.monospaced()).foregroundStyle(.secondary).help("Скопировать ссылку для ИИ")
                if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { save() }.keyboardShortcut(.defaultAction).accessibilityIdentifier("tasks.edit.save")
            }.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 520).frame(minHeight: 520, maxHeight: 760)
        .onAppear(perform: load)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dependencies: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 4) {
                ForEach(dependsOn, id: \.self) { id in
                    TaskChipPill(kind: .dependency, text: String((model.task(id: id)?.title ?? id.uuidString).prefix(28))) {
                        dependsOn.removeAll { $0 == id }
                    }
                }
            }
            TaskCombobox(
                text: .constant(""),
                options: model.tasks.filter { $0.deletedAt == nil && $0.id != task.id && !dependsOn.contains($0.id) }.map(\.title),
                placeholder: "название или код задачи"
            ) { chosen in
                guard let other = model.tasks.first(where: { $0.title == chosen || $0.code == chosen.uppercased() }) else {
                    if let id = model.resolveReference(chosen) { add(dependency: id) }
                    return
                }
                add(dependency: other.id)
            }
        }
    }

    private func add(dependency id: UUID) {
        guard !dependsOn.contains(id) else { return }
        if TaskDomain.wouldCreateCycle(adding: id, to: task.id, resolve: { model.task(id: $0) }) {
            failure = TasksFailure.cycle.errorDescription
            return
        }
        failure = nil
        dependsOn.append(id)
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Заметки\(notes.isEmpty ? "" : " (\(notes.count))")").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if editingNote == nil, newNote.isEmpty {
                    Button("+ заметка") { newNote = " " }.buttonStyle(.plain).font(.caption).foregroundStyle(TaskStyle.selection)
                }
            }
            ForEach(notes) { note in
                if editingNote == note.id {
                    noteBox(text: $noteDraft) {
                        if let index = notes.firstIndex(where: { $0.id == note.id }) {
                            notes[index].content = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        editingNote = nil
                    } cancel: {
                        editingNote = nil
                    }
                } else {
                    HStack(alignment: .top) {
                        Text(note.content).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            notes.removeAll { $0.id == note.id }
                        } label: {
                            Image(systemName: "xmark")
                        }.buttonStyle(.plain).controlSize(.mini).foregroundStyle(.secondary)
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                    .onTapGesture {
                        noteDraft = note.content
                        editingNote = note.id
                    }
                }
            }
            if !newNote.isEmpty {
                noteBox(text: $newNote) {
                    let trimmed = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { notes.insert(TaskNote(content: trimmed), at: 0) }
                    newNote = ""
                } cancel: {
                    newNote = ""
                }
            }
        }
    }

    private func noteBox(text: Binding<String>, save: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: text).font(.caption).frame(minHeight: 70).padding(4).background(
                Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Сохранить", action: save).controlSize(.small)
                Button("Отмена", action: cancel).controlSize(.small)
            }
        }
    }

    private func load() {
        title = task.title
        status = task.status
        priority = task.priority
        list = task.list ?? ""
        tags = task.tags
        personas = task.personas
        due = task.due.map { TaskDateFormat.dmy.string($0, calendar: model.calendar) } ?? ""
        start = task.start.map { TaskDateFormat.dmy.string($0, calendar: model.calendar) } ?? ""
        recurrence = task.recurrence ?? ""
        url = task.url?.absoluteString ?? ""
        estimate = task.estimateMinutes.map(TaskFieldInput.estimateText) ?? ""
        flow = task.flowID ?? ""
        dependsOn = task.dependsOn
        notes = task.notes
    }

    private func save() {
        var value = task
        let today = Date()
        value.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? task.title : title.trimmingCharacters(in: .whitespaces)
        value.priority = priority
        value.list = list.trimmingCharacters(in: .whitespaces).isEmpty ? nil : list.trimmingCharacters(in: .whitespaces)
        value.tags = tags
        value.personas = personas
        value.due = due.isEmpty ? nil : TaskFieldInput.date(due, today: today, calendar: model.calendar) ?? task.due
        value.start = start.isEmpty ? nil : TaskFieldInput.date(start, today: today, calendar: model.calendar) ?? task.start
        value.recurrence = recurrence.isEmpty ? nil : TaskRecurrence.normalize(recurrence)
        value.url = url.isEmpty ? nil : TaskFieldInput.url(url)
        value.estimateMinutes = estimate.isEmpty ? nil : TaskFieldInput.estimateMinutes(estimate)
        value.flowID = flow.trimmingCharacters(in: .whitespaces).isEmpty ? nil : flow.trimmingCharacters(in: .whitespaces)
        value.dependsOn = dependsOn
        var finalNotes = notes
        let pending = newNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty { finalNotes.insert(TaskNote(content: pending), at: 0) }
        if let editingNote, let index = finalNotes.firstIndex(where: { $0.id == editingNote }) {
            let draft = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !draft.isEmpty { finalNotes[index].content = draft }
        }
        value.notes = finalNotes
        let newStatus = status
        dismiss()
        _Concurrency.Task {
            if value != task { await model.update(value) }
            if newStatus != task.status { await model.set(status: newStatus, id: task.id) }
        }
    }
}

/// A text field with a list of known values underneath while typing.
struct TaskCombobox: View {
    @Binding var text: String
    let options: [String]
    let placeholder: String
    var onCommit: ((String) -> Void)? = nil
    @State private var typed = ""
    @FocusState private var focused: Bool

    private var matches: [String] {
        guard focused else { return [] }
        let query = (onCommit == nil ? text : typed).trimmingCharacters(in: .whitespaces)
        return options.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(placeholder, text: onCommit == nil ? $text : $typed).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit {
                    if let onCommit, !typed.trimmingCharacters(in: .whitespaces).isEmpty {
                        onCommit(typed.trimmingCharacters(in: .whitespaces))
                        typed = ""
                    }
                }
            if !matches.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(matches, id: \.self) { option in
                        Button(option) {
                            if let onCommit {
                                onCommit(option)
                                typed = ""
                            } else {
                                text = option
                            }
                            focused = false
                        }.buttonStyle(.plain).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                }
            }
        }
    }
}

/// A date typed in the quick-entry language, with a calendar popover beside it.
struct TaskDateField: View {
    @Binding var text: String
    let calendar: Calendar
    @State private var picking = false

    var body: some View {
        HStack(spacing: 4) {
            TextField("завтра, +3d, 20.04", text: $text).textFieldStyle(.roundedBorder)
            Button {
                picking.toggle()
            } label: {
                Image(systemName: "calendar")
            }.buttonStyle(.borderless)
                .popover(isPresented: $picking) {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { TaskFieldInput.date(text, today: Date(), calendar: calendar) ?? Date() },
                            set: { text = TaskDateFormat.dmy.string($0, calendar: calendar) }), displayedComponents: .date
                    ).datePickerStyle(.graphical).labelsHidden().padding(8)
                }
        }
    }
}

/// Chips with a combobox: Enter or a comma adds, Backspace on empty text removes the last.
struct TaskChipsField: View {
    @Binding var values: [String]
    let options: [String]
    let kind: TaskQuickEntry.Kind
    let placeholder: String
    let prefix: String
    var stripSpaces = false
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 4) {
                ForEach(values, id: \.self) { value in
                    TaskChipPill(kind: kind, text: prefix + value) { values.removeAll { $0 == value } }
                }
                TextField(placeholder, text: $typed).textFieldStyle(.plain).frame(minWidth: 120).focused($focused)
                    .onSubmit { add(typed) }
                    .onChange(of: typed) { _, value in
                        if value.hasSuffix(",") { add(String(value.dropLast())) }
                    }
                    .onKeyPress(.delete) {
                        guard typed.isEmpty, !values.isEmpty else { return .ignored }
                        values.removeLast()
                        return .handled
                    }
            }
            .padding(8).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.1)))
            if focused {
                let matches = options.filter { !values.contains($0) && (typed.isEmpty || $0.localizedCaseInsensitiveContains(typed)) }
                    .prefix(6)
                if !matches.isEmpty {
                    FlowLayout(spacing: 4) {
                        ForEach(Array(matches), id: \.self) { option in
                            Button(prefix + option) { add(option) }.buttonStyle(.plain).font(.caption).padding(.horizontal, 6).padding(
                                .vertical, 2
                            )
                            .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private func add(_ raw: String) {
        var cleaned = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: prefix, with: "")
        if stripSpaces { cleaned = cleaned.replacingOccurrences(of: " ", with: "") }
        typed = ""
        guard !cleaned.isEmpty, !values.contains(cleaned) else { return }
        values.append(cleaned)
    }
}
