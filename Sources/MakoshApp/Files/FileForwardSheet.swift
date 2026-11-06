import MakoshFiles
import SwiftUI

/// Picks a chat or an address for a file. The workspace stages the file and
/// opens the composer; the person sends it from there.
struct FileForwardSheet: View {
    let request: FileForwardRequest
    let destinations: [FileDestination]
    /// Nil on success, else the text to show.
    let perform: (FileDestination) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var busy = false
    @State private var failure: String?

    private var shown: [FileDestination] { FileDestinationSearch.rank(destinations, query: query, limit: 50) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(request.mode == .chat ? "Отправить в чат…" : "Отправить письмом…").font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            Label(request.handoff.name, systemImage: "paperclip").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            TextField(request.mode == .chat ? "Чат Telegram или WhatsApp" : "Контакт или адрес", text: $query).textFieldStyle(
                .roundedBorder
            )
            .accessibilityIdentifier("files.forward.search")
            if destinations.isEmpty {
                ContentUnavailableView(
                    request.mode == .chat ? "Нет открытых чатов" : "Нет контактов с адресом",
                    systemImage: request.mode == .chat ? "bubble.left" : "envelope",
                    description: Text(
                        request.mode == .chat
                            ? "Подключите Telegram или WhatsApp и откройте список чатов." : "Добавьте адрес в досье контакта.")
                ).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List(shown) { destination in
                    Button {
                        choose(destination)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(destination.title).lineLimit(1)
                            Text(destination.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain).disabled(busy).accessibilityIdentifier("files.forward.destination.\(destination.id)")
                }.listStyle(.plain).frame(minHeight: 260)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            if busy { ProgressView().controlSize(.small) }
        }
        .padding(16).frame(width: 460)
    }

    private func choose(_ destination: FileDestination) {
        guard !busy else { return }
        busy = true
        Task {
            if let problem = await perform(destination) {
                failure = problem
                busy = false
            } else {
                dismiss()
            }
        }
    }
}
