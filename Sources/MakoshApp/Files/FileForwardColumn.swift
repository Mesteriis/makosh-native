import MakoshFiles
import SwiftUI

/// The forward chooser as a right-hand column beside the section's content,
/// like the AI panel beside a chat. The workspace stages the file and opens
/// the composer; the person sends it from there.
struct FileForwardColumn: ViewModifier {
    @ObservedObject var host: FilesHost
    let destinations: (FileForwardRequest.Mode) -> [FileDestination]
    let perform: (FileForwardRequest, FileDestination) async -> String?

    func body(content: Content) -> some View {
        HStack(spacing: 0) {
            content
            if let request = host.pendingForward {
                Divider()
                FileForwardPanel(
                    request: request, destinations: destinations(request.mode), perform: { await perform(request, $0) },
                    close: { host.pendingForward = nil }
                )
                .frame(width: 320)
                .background { WorkspaceBackdrop(intensity: 0.55) }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: host.pendingForward?.id)
    }
}

struct FileForwardPanel: View {
    let request: FileForwardRequest
    let destinations: [FileDestination]
    /// Nil on success, else the text to show.
    let perform: (FileDestination) async -> String?
    let close: () -> Void
    @State private var query = ""
    @State private var busy = false
    @State private var failure: String?

    private var shown: [FileDestination] { FileDestinationSearch.rank(destinations, query: query, limit: 50) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(request.mode == .chat ? "Отправить в чат" : "Отправить письмом").font(.headline)
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.plain).help("Закрыть").disabled(busy).accessibilityIdentifier("files.forward.close")
            }
            Label(request.handoff.name, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            TextField(request.mode == .chat ? "Чат Telegram или WhatsApp" : "Персона или адрес", text: $query).textFieldStyle(
                .roundedBorder
            )
            .accessibilityIdentifier("files.forward.search")
            if destinations.isEmpty {
                ContentUnavailableView(
                    request.mode == .chat ? "Нет открытых чатов" : "Нет персон с адресом",
                    systemImage: request.mode == .chat ? "bubble.left" : "envelope",
                    description: Text(
                        request.mode == .chat
                            ? "Подключите Telegram или WhatsApp и откройте список чатов." : "Добавьте адрес в досье персоны.")
                ).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(shown) { destination in
                    Button {
                        choose(destination)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(destination.title).lineLimit(1)
                            Text(destination.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(busy).accessibilityIdentifier("files.forward.destination.\(destination.id)")
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(16).frame(maxHeight: .infinity, alignment: .top)
    }

    private func choose(_ destination: FileDestination) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task {
            if let problem = await perform(destination) {
                failure = problem
                busy = false
            } else {
                close()
            }
        }
    }
}
