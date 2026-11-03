import SwiftUI
import QuickLookUI
import MakoshTelegram

struct TelegramArchivedFilePreviewView: View {
    let preview: TelegramArchivedFilePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(preview.name, systemImage: "paperclip").font(.headline).lineLimit(2)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("telegram.archive.file.preview.close")
            }
            Text("Сохранённая копия из S3 · доступна после удаления сообщения в Telegram")
                .font(.caption).foregroundStyle(.secondary)
            TelegramArchiveQuickLook(preview: preview)
                .accessibilityIdentifier("telegram.archive.file.preview.content")
        }
        .padding(20).frame(minWidth: 620, idealWidth: 760, minHeight: 440, idealHeight: 600)
    }
}

/// SwiftUI owns presentation; the preview item retains the private file until
/// Quick Look is closed, even if SwiftUI releases its sheet value first.
private struct TelegramArchiveQuickLook: NSViewRepresentable {
    let preview: TelegramArchivedFilePreview

    func makeCoordinator() -> Coordinator { Coordinator(preview: preview) }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = context.coordinator.item
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.item?.preview.id != preview.id else { return }
        let item = Item(preview: preview)
        view.previewItem = item
        context.coordinator.item = item
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
        coordinator.item = nil
    }

    final class Coordinator {
        var item: Item?
        init(preview: TelegramArchivedFilePreview) { item = Item(preview: preview) }
    }

    final class Item: NSObject, QLPreviewItem {
        let preview: TelegramArchivedFilePreview
        init(preview: TelegramArchivedFilePreview) { self.preview = preview }
        var previewItemURL: URL! { preview.file }
        var previewItemTitle: String! { preview.name }
    }
}
