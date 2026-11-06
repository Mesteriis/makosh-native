import MakoshFiles
import SwiftUI

/// "Отправить в Paperless…" for any file. Without a connection it points to
/// the settings; without a Files host (isolated previews, tests) it is nothing.
struct FileSendMenu: View {
    var title = "Отправить в Paperless…"
    let handoff: () -> FileHandoff
    /// Where the request goes; by default the workspace sheet.
    var present: ((FileSendRequest) -> Void)? = nil
    @Environment(\.filesHost) private var files

    var body: some View {
        if let files {
            if files.model.connections.isEmpty {
                SettingsLink { Text("Подключить Paperless…") }.accessibilityIdentifier("files.send.connect")
            } else {
                Button(title) {
                    let request = FileSendRequest(handoff: handoff())
                    if let present { present(request) } else { files.pendingSend = request }
                }.accessibilityIdentifier("files.send.paperless")
            }
        }
    }
}
