import MakoshWhatsApp
import QuickLookUI
import SwiftUI

struct WhatsAppFilePreview: View {
  let lease: WhatsAppFileLease
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(lease.url.lastPathComponent).lineLimit(1)
        Spacer()
        ShareLink(item: lease.url)
        Button("Закрыть") { dismiss() }
      }.padding(12)
      WhatsAppQuickLook(url: lease.url)
    }.frame(minWidth: 650, minHeight: 500)
  }
}
private struct WhatsAppQuickLook: NSViewRepresentable {
  let url: URL
  func makeNSView(context: Context) -> NSView {
    guard let view = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
    view.autostarts = true
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    (view as? QLPreviewView)?.previewItem = url as NSURL
  }
  static func dismantleNSView(_ view: NSView, coordinator: ()) {
    (view as? QLPreviewView)?.previewItem = nil
    (view as? QLPreviewView)?.close()
  }
}
