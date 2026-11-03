import AppKit
import MakoshWhatsApp
import SwiftUI

struct WhatsAppContactCard: View {
  let contact: WhatsAppContactPresentation
  let rawSource: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Label(contact.name, systemImage: "person.crop.rectangle").font(.headline)
      ForEach(contact.fields) { field in
        VStack(alignment: .leading, spacing: 2) {
          Text(field.label).font(.caption).foregroundStyle(.secondary)
          Text(field.value).textSelection(.enabled)
        }
      }
      if contact.isMalformed {
        Text("Часть карточки не удалось прочитать").font(.caption).foregroundStyle(.secondary)
      }
      if let rawSource, !rawSource.isEmpty {
        DisclosureGroup("Исходная карточка") {
          Text(contact.sourcePreview).font(.caption.monospaced()).textSelection(.enabled)
          if contact.sourceTruncated { Text("Показан фрагмент карточки").font(.caption) }
          Button("Скопировать исходную карточку") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rawSource, forType: .string)
          }
        }.font(.caption)
      }
    }.accessibilityIdentifier("whatsapp.contactCard")
  }
}
