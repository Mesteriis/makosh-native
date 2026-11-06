import MakoshFiles
import SwiftUI

/// Picks a chat or a letter for a file; filled in by the forwarding task.
struct FileForwardSheet: View {
    let request: FileForwardRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text(request.mode == .chat ? "Отправить в чат…" : "Отправить письмом…").font(.headline)
            Text("Выбор адресата появится в следующем шаге.").foregroundStyle(.secondary)
            Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 420)
    }
}
