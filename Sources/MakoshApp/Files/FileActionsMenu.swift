import MakoshAI
import MakoshFiles
import SwiftUI

/// The file's actions for any context menu: Paperless, a chat, a letter, the
/// AI. Protected content gets nothing; without a Files host (isolated
/// previews, tests) nothing is shown either.
struct FileActionsMenu: View {
    let handoff: () -> FileHandoff
    /// Known archive record or Paperless document; nil stages a private copy for the AI.
    var source: AIFileSource? = nil
    var protected = false
    /// Where a Paperless request goes; by default the workspace sheet.
    var present: ((FileSendRequest) -> Void)? = nil
    /// Runs before any request is raised, e.g. to close the sheet the menu
    /// lives in. The file is staged first, so a lease the sheet owns may go.
    var before: (() -> Void)? = nil
    @Environment(\.filesHost) private var files
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let files {
            let actions = FileActions.available(protected: protected, hasPaperless: !files.model.connections.isEmpty)
            ForEach(actions, id: \.self) { action in
                Button(action.title) { perform(action, in: files) }.accessibilityIdentifier("files.action.\(identifier(action))")
            }
            if !protected, !actions.contains(.sendToPaperless) {
                Button("Подключить Paperless…") {
                    UserDefaults.standard.set(MakoshSettingsTab.files, forKey: MakoshSettingsTab.key)
                    openSettings()
                }.accessibilityIdentifier("files.send.connect")
            }
        }
    }

    private func perform(_ action: FileAction, in files: FilesHost) {
        let original = handoff()
        guard let before else { return raise(action, handoff: original, in: files) }
        Task {
            do {
                let staged = try await files.stage.stage(original)
                before()
                raise(action, handoff: FileHandoff(copying: staged.url, name: original.name, date: original.date), in: files)
            } catch {
                files.model.error =
                    (error as? FilesFailure)?.errorDescription ?? (error as? LocalizedError)?.errorDescription
                    ?? "Не удалось подготовить файл."
            }
        }
    }

    private func raise(_ action: FileAction, handoff: FileHandoff, in files: FilesHost) {
        switch action {
        case .sendToPaperless:
            let request = FileSendRequest(handoff: handoff)
            if let present { present(request) } else { files.pendingSend = request }
        case .forwardToChat: files.pendingForward = FileForwardRequest(handoff: handoff, mode: .chat)
        case .forwardByMail: files.pendingForward = FileForwardRequest(handoff: handoff, mode: .mail)
        case .askAI: files.pendingAsk = FileAskRequest(handoff: handoff, source: source)
        }
    }

    private func identifier(_ action: FileAction) -> String {
        switch action {
        case .sendToPaperless: "paperless"
        case .forwardToChat: "chat"
        case .forwardByMail: "mail"
        case .askAI: "ask"
        }
    }
}
