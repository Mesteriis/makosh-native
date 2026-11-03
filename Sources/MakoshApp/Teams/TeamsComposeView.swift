import SwiftUI
import MakoshTeams

struct TeamsComposeView: View {
    @ObservedObject var model: TeamsWorkspaceModel
    @ObservedObject var composer: TeamsComposerModel
    @State private var choosingFolder = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = composer.error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let notice = composer.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let error = model.fileError { Text(error).font(.caption).foregroundStyle(.orange) }
            ForEach(composer.attachments) { file in
                HStack { Label(file.name, systemImage: "doc").lineLimit(1); Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary); Spacer(); Button { composer.attachments.removeAll { $0.id == file.id } } label: { Image(systemName: "xmark.circle") }.help("Убрать файл из сообщения") }.font(.callout)
            }
            if let plan = composer.accessPlan {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Доступ на чтение · \(plan.folderName)").font(.callout.bold())
                    Text(plan.recipients.isEmpty ? "Только ваш аккаунт" : plan.recipients.map(\.displayName).joined(separator: ", ")).font(.caption).textSelection(.enabled)
                    Text("Получатели должны войти в Microsoft. Приглашения по почте и публичные ссылки не создаются. Перед отправкой состав участников проверится ещё раз.").font(.caption).foregroundStyle(.secondary)
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("teams.files.accessReview")
            }
            TextEditor(text: $composer.text).frame(minHeight: 54, maxHeight: 110).font(.body).scrollContentBackground(.hidden).padding(6).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("Сообщение Teams").accessibilityIdentifier("teams.compose.text")
            HStack {
                Button { chooseFiles() } label: { Label("Файлы", systemImage: "paperclip") }.disabled(!model.filesAvailable || composer.preparing || composer.attachments.count >= 10 || !model.canSend).accessibilityIdentifier("teams.compose.attach")
                if !composer.attachments.isEmpty { Button("Папка и получатели…") { choosingFolder = true }.disabled(composer.preparing || composer.reviewing || !model.canSend).accessibilityIdentifier("teams.compose.access") }
                if composer.preparing || composer.reviewing || composer.sending { ProgressView().controlSize(.small) }
                Spacer()
                Button(composer.attachments.isEmpty ? "Отправить" : "Подтвердить доступ и отправить") { Task { await composer.send(); await model.refresh() } }.keyboardShortcut(.return, modifiers: .command).disabled(!composer.canSend || !model.canSend).accessibilityIdentifier("teams.compose.send")
            }
            if !model.canSend { Text("Для отправки подключите аккаунт и предоставьте отдельное разрешение на сообщения. Режим «Только чтение» запрещает отправку.").font(.caption).foregroundStyle(.secondary) }
        }.padding(14)
        .sheet(isPresented: $choosingFolder) { if let scope = model.selectedScope { TeamsDriveFolderPicker(worker: model.worker, scope: scope) { destination in Task { guard model.selectedScope == scope else { return }; await composer.reviewFiles(destination: destination) } } } }
    }
    private func chooseFiles() {
        let scope = model.selectedScope
        Task {
            let files = await TeamsFilePanels.chooseFiles()
            guard scope == model.selectedScope, !files.isEmpty else { return }
            await composer.attach(files)
        }
    }
}

struct TeamsDriveFolderPicker: View {
    let worker: any TeamsServing
    let scope: TeamsScope
    var selected: (TeamsFileDestination) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var parent: TeamsDriveFolderChoice?
    @State private var values: [TeamsDriveFolderChoice] = []
    @State private var next: TeamsContinuation?
    @State private var parentID: String?
    @State private var stack: [String?] = []
    @State private var busy = false
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Папка для файлов").font(.title2.bold()); Spacer(); Button("Отмена") { dismiss() } }
            Text("OneDrive · \(parent?.name ?? "Загрузка…")").font(.headline)
            HStack {
                Button("Назад") { if let previous = stack.popLast() { parentID = previous; Task { await load(reset: true) } } }.disabled(stack.isEmpty || busy)
                Spacer()
                Button("Выбрать эту папку") { if let parent { selected(.ownDrive(folderID: parent.id)); dismiss() } }.disabled(parent == nil || busy).accessibilityIdentifier("teams.folder.select")
            }
            List(values) { folder in Button { stack.append(parentID); parentID = folder.id; Task { await load(reset: true) } } label: { Label(folder.name, systemImage: "folder") }.buttonStyle(.plain).disabled(busy) }
            if next != nil { Button("Загрузить ещё папки") { Task { await load(reset: false) } }.disabled(busy) }
            if case let .channel(team, channel) = scope.policyScope.resource { Button("Использовать папку канала") { selected(.channel(teamID: team, channelID: channel)); dismiss() }.disabled(busy) }
            Text("Папка проверится перед выдачей доступа. Широкие ссылки и неподтверждённый состав доступа блокируют публикацию.").font(.caption).foregroundStyle(.secondary)
            if busy { ProgressView() }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(20).frame(width: 560, height: 500).task { await load(reset: true) }.onDisappear { generation = UUID() }
    }
    private func load(reset: Bool) async {
        guard !busy else { return }; let token = UUID(); generation = token; busy = true; error = nil
        if reset { parent = nil; values = []; next = nil }
        defer { if generation == token { busy = false } }
        do {
            let page = try await worker.fileFolders(scope: scope, parentID: parentID, continuation: reset ? nil : next)
            guard generation == token, !Task.isCancelled else { return }
            parent = page.parent; values = reset ? page.values : values + page.values; next = page.next
        } catch { if generation == token { self.error = teamsFailureMessage(error) } }
    }
}
