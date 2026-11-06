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
    /// Runs before any request is raised, e.g. to close the sheet the menu lives in.
    var before: (() -> Void)? = nil
    @Environment(\.filesHost) private var files

    var body: some View {
        if let files {
            let actions = FileActions.available(protected: protected, hasPaperless: !files.model.connections.isEmpty)
            if actions.isEmpty, !protected {
                SettingsLink { Text("Подключить Paperless…") }.accessibilityIdentifier("files.send.connect")
            }
            ForEach(actions, id: \.self) { action in
                Button(action.title) { perform(action, in: files) }.accessibilityIdentifier("files.action.\(identifier(action))")
            }
            if !protected, !actions.contains(.sendToPaperless) {
                SettingsLink { Text("Подключить Paperless…") }.accessibilityIdentifier("files.send.connect")
            }
        }
    }

    private func perform(_ action: FileAction, in files: FilesHost) {
        before?()
        switch action {
        case .sendToPaperless:
            let request = FileSendRequest(handoff: handoff())
            if let present { present(request) } else { files.pendingSend = request }
        case .forwardToChat: files.pendingForward = FileForwardRequest(handoff: handoff(), mode: .chat)
        case .forwardByMail: files.pendingForward = FileForwardRequest(handoff: handoff(), mode: .mail)
        case .askAI: files.pendingAsk = FileAskRequest(handoff: handoff(), source: source)
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
