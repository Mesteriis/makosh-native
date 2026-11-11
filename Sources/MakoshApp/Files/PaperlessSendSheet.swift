import AppKit
import MakoshFiles
import SwiftUI

/// Title, date, type and tags, then the submission's progress. Closing the
/// sheet never stops the submission: the sender keeps it in its journal.
struct PaperlessSendSheet: View {
    @ObservedObject var model: FilesWorkspaceModel
    let request: FileSendRequest
    @Environment(\.dismiss) private var dismiss
    @State private var connectionID: UUID?
    @State private var title = ""
    @State private var created: Date = .now
    @State private var hasDate = false
    @State private var documentType: Int?
    @State private var tags: Set<Int> = []
    @State private var lists: PaperlessLists?
    @State private var submission: PaperlessSubmission?
    @State private var sending = false
    @State private var prepared = false
    /// Chosen before sending, so the sheet follows exactly its own submission.
    @State private var submissionID = UUID()

    private var connections: [PaperlessConnection] {
        model.connections.compactMap { if case .paperless(let value) = $0 { value } else { nil } }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Файл") { Text(request.handoff.name).lineLimit(2) }
                if connections.count > 1 {
                    MakoshPicker("Подключение", selection: $connectionID) {
                        ForEach(connections) { Text($0.name).tag(Optional($0.id)) }
                    }.onChange(of: connectionID) { _, _ in Task { await prepare() } }
                }
                WorkspaceLabeledField("Название") {
                    TextField("Название", text: $title).onChange(of: title) { _, value in
                        if value.count > PaperlessUpload.titleLimit { title = String(value.prefix(PaperlessUpload.titleLimit)) }
                    }.accessibilityIdentifier("files.send.title")
                }
                Toggle("Дата документа", isOn: $hasDate)
                if hasDate { DatePicker("", selection: $created, displayedComponents: .date).labelsHidden() }
                if let lists {
                    MakoshPicker("Тип документа", selection: $documentType) {
                        Text("Не задан").tag(Int?.none)
                        ForEach(lists.types) { Text($0.name).tag(Int?.some($0.id)) }
                    }
                    if !lists.tags.isEmpty {
                        DisclosureGroup("Теги · \(tags.count)") {
                            ForEach(lists.tags) { tag in
                                Toggle(
                                    tag.name,
                                    isOn: Binding(
                                        get: { tags.contains(tag.id) }, set: { if $0 { tags.insert(tag.id) } else { tags.remove(tag.id) } })
                                )
                            }
                        }
                    }
                } else if connectionID != nil {
                    Text("Типы и теги не загружены — документ уйдёт с настройками подключения.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let submission {
                Section {
                    HStack(spacing: 10) {
                        if !submission.isSettled && submission.state != .unknown { ProgressView().controlSize(.small) }
                        Text(submission.state.title).accessibilityIdentifier("files.send.state")
                        Spacer()
                        if case .accepted(let id?) = submission.state, let url = model.documentURL(id: id, in: submission.connectionID) {
                            Button("Открыть в Paperless") { NSWorkspace.shared.open(url) }
                        }
                        if !submission.isSettled, submission.taskID != nil {
                            Button("Проверить") { Task { await model.check(submission.id) } }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(submission == nil ? "Отмена" : "Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                if submission == nil {
                    Button("Отправить", action: send).keyboardShortcut(.defaultAction)
                        .disabled(sending || connectionID == nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("files.send.submit")
                }
            }
        }
        .formStyle(WorkspaceFormStyle()).frame(width: 520)
        .task {
            guard !prepared else { return }
            prepared = true
            connectionID = connections.first?.id
            await prepare()
        }
        .onReceive(model.$submissions) { all in
            if let updated = all.first(where: { $0.id == submissionID }) { submission = updated }
        }
    }

    private func prepare() async {
        guard let id = connectionID, let connection = connections.first(where: { $0.id == id }) else { return }
        let defaults = PaperlessUpload.defaults(for: request.handoff, connection: connection)
        title = defaults.title
        hasDate = defaults.created != nil
        created = defaults.created ?? .now
        documentType = defaults.documentType
        tags = Set(defaults.tags)
        if let known = model.lists[id] { lists = known } else { lists = await model.lists(for: id) }
    }

    private func send() {
        guard let connectionID else { return }
        sending = true
        let options = PaperlessUpload(
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PaperlessUpload.titleLimit)),
            created: hasDate ? created : nil, documentType: documentType, tags: tags.sorted())
        let handoff = request.handoff, id = submissionID
        Task {
            let result = await model.send(handoff, to: connectionID, options: options, id: id)
            submission = result
            sending = false
        }
    }
}
