import MakoshFiles
import SwiftUI

/// The selected storage; filled in by the Paperless browser task.
struct PaperlessDocumentsView: View {
    @ObservedObject var model: FilesWorkspaceModel
    let connectionID: UUID

    var body: some View {
        ContentUnavailableView(
            "Архив Paperless", systemImage: "archivebox", description: Text("Просмотр документов появится в следующем шаге.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "Send to Paperless…" for any file; filled in by the sending task.
struct FileSendMenu: View {
    @ObservedObject var host: FilesHost
    let handoff: () -> FileHandoff

    var body: some View {
        EmptyView()
    }
}
