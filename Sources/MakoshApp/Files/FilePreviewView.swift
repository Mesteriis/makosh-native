import MakoshFiles
import QuickLookUI
import SwiftUI

struct FilePreviewView: View {
    let lease: FilePreviewLease
    var caption = "Сохранённая копия из архива Макоша"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(lease.name, systemImage: "paperclip").font(.headline).lineLimit(2)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("files.preview.close")
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
            FileQuickLook(lease: lease).accessibilityIdentifier("files.preview.content")
        }
        .padding(20).frame(minWidth: 620, idealWidth: 760, minHeight: 440, idealHeight: 600)
    }
}

/// The preview item retains the private file until Quick Look is closed,
/// even if SwiftUI releases its sheet value first.
private struct FileQuickLook: NSViewRepresentable {
    let lease: FilePreviewLease

    func makeCoordinator() -> Coordinator { Coordinator(lease: lease) }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = context.coordinator.item
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.item?.lease.id != lease.id else { return }
        let item = Item(lease: lease)
        view.previewItem = item
        context.coordinator.item = item
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
        coordinator.item = nil
    }

    final class Coordinator {
        var item: Item?
        init(lease: FilePreviewLease) { item = Item(lease: lease) }
    }

    final class Item: NSObject, QLPreviewItem {
        let lease: FilePreviewLease
        init(lease: FilePreviewLease) { self.lease = lease }
        var previewItemURL: URL! { lease.file }
        var previewItemTitle: String! { lease.name }
    }
}
