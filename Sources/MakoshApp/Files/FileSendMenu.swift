import MakoshFiles
import SwiftUI

/// "Send to Paperless…" for any file; filled in by the sending task.
struct FileSendMenu: View {
    @ObservedObject var host: FilesHost
    let handoff: () -> FileHandoff

    var body: some View {
        EmptyView()
    }
}
