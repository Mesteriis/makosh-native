import AppKit
import SwiftUI
import MakoshTelegram

@MainActor struct TelegramCustomEmojiPicker: View {
    @ObservedObject var catalog: TelegramCustomEmojiCatalogController
    let playbackContext: TelegramCustomEmojiPlaybackContext?
    let chatID: Int64
    let choose: (TelegramCustomEmojiDescriptor, UUID) -> Void
    @State private var query = ""
    @State private var showingPack = false
    private let columns = Array(repeating: GridItem(.fixed(40), spacing: 0), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if showingPack {
                    Button { showingPack = false } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).accessibilityLabel("Назад к наборам эмодзи")
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Поиск", text: $query).textFieldStyle(.plain)
                        .accessibilityIdentifier("telegram.customEmoji.search")
                }
                .padding(.horizontal, 8).frame(height: 30)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            }.padding(.horizontal, 8).frame(height: 46)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !catalog.searchIsFinal { ProgressView().controlSize(.small) }
                        grid(catalog.searchResults)
                        if catalog.searchIsFinal && catalog.searchResults.isEmpty { Text("Эмодзи не найдены").foregroundStyle(.secondary) }
                    } else if showingPack {
                        packPage
                    } else if let snapshot = catalog.snapshot {
                        if !snapshot.recent.isEmpty {
                            Text("Недавние").font(.system(size: 13, weight: .semibold))
                            grid(snapshot.recent)
                        }
                        ForEach(snapshot.installed) { pack in packSection(pack, preview: false) }
                        ForEach(snapshot.featured.filter { featured in !snapshot.installed.contains(where: { $0.id == featured.id }) }) { pack in
                            packSection(pack, preview: true)
                        }
                        if snapshot.recent.isEmpty && snapshot.installed.isEmpty && snapshot.featured.isEmpty {
                            Text("Нет доступных наборов эмодзи").foregroundStyle(.secondary)
                        }
                    } else { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 10).padding(.vertical, 10)
            }
        }
        .font(.system(size: 13)).frame(width: 340, height: 420)
        .accessibilityIdentifier("telegram.customEmoji.picker")
        .onChange(of: query) { _, value in showingPack = false; catalog.search(query: value) }
        .onChange(of: catalog.contextID) { _, _ in query = ""; showingPack = false }
    }
    private var packPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            if catalog.packIsLoading { ProgressView().controlSize(.small) }
            if let pack = catalog.selectedPack {
                HStack {
                    Text(pack.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 8)
                    let installed = catalog.snapshot?.installed.contains(where: { $0.id == pack.id }) ?? pack.installed
                    Button(installed ? "Удалить" : "Добавить") { catalog.setInstalled(!installed) }
                        .disabled(catalog.mutationIsPending || !pack.itemsComplete)
                        .accessibilityIdentifier("telegram.customEmoji.pack.install")
                }
                grid(pack.items)
            } else if !catalog.packIsLoading { Text("Набор недоступен").foregroundStyle(.secondary) }
        }
    }
    private func packSection(_ pack: TelegramCustomEmojiPack, preview: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                catalog.loadPack(reference: pack.reference); showingPack = true
            } label: {
                HStack {
                    Text(pack.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            grid(preview ? Array(pack.items.prefix(23)) : pack.items)
            if preview && pack.itemCount > 23 {
                Button("Показать все · \(pack.itemCount)") { catalog.loadPack(reference: pack.reference); showingPack = true }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }
    private func grid(_ items: [TelegramCustomEmojiDescriptor]) -> some View {
        let context = catalog.contextID
        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(items) { descriptor in
                let allowed = catalog.canInsert(descriptor, chatID: chatID)
                Button {
                    guard catalog.contextID == context, catalog.canInsert(descriptor, chatID: chatID) else { return }
                    choose(descriptor, context)
                } label: {
                    TelegramCustomEmojiPickerCell(descriptor: descriptor, context: playbackContext,
                        locked: descriptor.isPremium && !allowed)
                }
                .buttonStyle(.plain).disabled(!allowed)
                .accessibilityLabel(descriptor.fallbackText)
                .accessibilityHint(descriptor.isPremium && !allowed ? "Требуется Telegram Premium" : "Вставить эмодзи")
            }
        }
    }
}
@MainActor private struct TelegramCustomEmojiPickerCell: View {
    let descriptor: TelegramCustomEmojiDescriptor
    let context: TelegramCustomEmojiPlaybackContext?
    let locked: Bool
    @StateObject private var playback = TelegramCustomEmojiPlaybackController()
    @State private var visible = false
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                Text(descriptor.fallbackText).font(.system(size: 24)).opacity(playback.frame == nil ? 1 : 0)
                if let frame = playback.frame, let image = image(frame) {
                    Image(nsImage: image).renderingMode(descriptor.isSingleColor ? .template : .original)
                        .resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28).accessibilityHidden(true)
                }
            }.frame(width: 40, height: 34)
            if locked { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.secondary).padding(2) }
        }.frame(width: 40, height: 34).contentShape(Rectangle())
        .onScrollVisibilityChange(threshold: 0.01) { value in visible = value; refresh() }
        .onChange(of: context?.id) { _, _ in refresh() }
        .onChange(of: descriptor) { _, _ in refresh() }
        .onDisappear { visible = false; playback.stop() }
    }
    private func refresh() {
        playback.bind(context: context)
        if visible { playback.play(descriptor: descriptor, width: 56, height: 56) } else { playback.stop() }
    }
    private func image(_ frame: TelegramCustomEmojiFrame) -> NSImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: frame.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: frame.width, height: frame.height))
    }
}
