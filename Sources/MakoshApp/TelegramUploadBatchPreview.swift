import SwiftUI
import MakoshTelegram

/// The reference uses visual mosaics in chunks of ten, and individual file rows.
struct TelegramUploadBatchPreview: View {
    @ObservedObject var upload: TelegramUploadController
    let contextID: UUID
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let items = upload.presentedItems
        ScrollView {
            VStack(spacing: 10) {
                if upload.isVisualMedia && upload.isGrouped {
                    ForEach(Array(stride(from: 0, to: items.count, by: 10)), id: \.self) { start in
                        let group = Array(items[start..<min(start + 10, items.count)])
                        TelegramUploadMosaicLayout(items: group, scale: displayScale) {
                            ForEach(group) { item in
                                itemView(item, compact: true)
                            }
                        }.clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    ForEach(items) { item in itemView(item, compact: false) }
                }
            }.frame(maxWidth: .infinity)
        }.frame(maxHeight: 320)
            .accessibilityIdentifier("telegram.upload.items")
    }

    private func itemView(_ item: TelegramUploadBatchItem, compact: Bool) -> some View {
        let revision = upload.itemsRevision
        let position = upload.items.firstIndex(where: { $0.id == item.id }) ?? 0
        return HStack(spacing: 8) {
            Button { upload.selectItem(id: item.id, contextID: contextID) } label: {
                if item.file.mode == .file {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.fill").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.file.name).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: item.file.size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(10)
                } else {
                    TelegramUploadBatchTile(item: item, spoiler: upload.mediaSpoiler, compact: compact)
                }
            }.buttonStyle(.plain)
                .accessibilityLabel("Вложение \(position + 1): \(item.file.name)")
                .accessibilityValue(upload.selectedItemID == item.id ? "Выбрано" : "")
                .accessibilityIdentifier("telegram.upload.item." + item.id.uuidString.lowercased())
            if !compact {
                Menu { actions(item, position: position, revision: revision) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().padding(.trailing, 8)
                    .accessibilityLabel("Действия с \(item.file.name)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .overlay { if upload.selectedItemID == item.id { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2) } }
        .contextMenu { actions(item, position: position, revision: revision) }
        .draggable(contextID.uuidString + ":" + revision.uuidString + ":" + item.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard values.count == 1 else { return false }
            let parts = values[0].split(separator: ":")
            guard parts.count == 3, let context = UUID(uuidString: String(parts[0])),
                  let sourceRevision = UUID(uuidString: String(parts[1])), let id = UUID(uuidString: String(parts[2])) else { return false }
            return upload.moveItem(id: id, to: position, contextID: context, revision: sourceRevision)
        }
    }

    @ViewBuilder private func actions(_ item: TelegramUploadBatchItem, position: Int, revision: UUID) -> some View {
        Button("Переместить выше") { upload.moveItem(id: item.id, to: position - 1, contextID: contextID, revision: revision) }
            .disabled(!upload.canEditItems || position == 0)
        Button("Переместить ниже") { upload.moveItem(id: item.id, to: position + 1, contextID: contextID, revision: revision) }
            .disabled(!upload.canEditItems || position + 1 == upload.items.count)
        Divider()
        Button("Удалить из подготовки") { upload.removeItem(id: item.id, contextID: contextID, revision: revision) }
            .disabled(!upload.canEditItems)
    }
}
private struct TelegramUploadMosaicLayout: Layout {
    let items: [TelegramUploadBatchItem]
    let scale: Double
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(420, max(16, proposal.width ?? 360))
        let layout = TelegramUploadPreviewMosaic.layout(items: items, width: width, scale: scale)
        return CGSize(width: width, height: layout.dimensions.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = TelegramUploadPreviewMosaic.layout(items: items, width: bounds.width, scale: scale)
        let inset = (bounds.width - layout.dimensions.width) / 2
        for (view, frame) in zip(subviews, layout.frames) {
            view.place(at: CGPoint(x: bounds.minX + inset + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

private struct TelegramUploadBatchTile: View {
    let item: TelegramUploadBatchItem
    let spoiler: Bool
    let compact: Bool
    @State private var preview: TelegramImagePreview?
    @State private var failed = false
    private var previewID: String { item.file.id.uuidString + ":" + (item.file.videoCover?.id.uuidString ?? "frame") }
    var body: some View {
        Group {
            if compact { content.frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { TelegramUploadSingleMediaLayout(file: item.file) { content } }
        }
        .clipped()
        .task(id: previewID) {
            preview = nil; failed = false
            do {
                let value = try await TelegramUploadFileIO.preview(item.file)
                guard !Task.isCancelled else { return }; preview = value
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
    private var content: some View {
        ZStack(alignment: .bottomLeading) {
            if let preview {
                Image(preview.image, scale: 1, label: Text(item.file.name)).resizable()
                    .aspectRatio(contentMode: compact ? .fill : .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).blur(radius: spoiler ? 18 : 0)
                    .accessibilityHidden(spoiler)
            } else if failed { Image(systemName: "photo.badge.exclamationmark").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            if spoiler { Label("Спойлер", systemImage: "eye.slash").padding(6).background(.thinMaterial) }
            else if item.file.mode == .video { Label(item.file.name, systemImage: "video.fill").font(.caption).lineLimit(1).padding(6).background(.thinMaterial) }
        }
    }
}
