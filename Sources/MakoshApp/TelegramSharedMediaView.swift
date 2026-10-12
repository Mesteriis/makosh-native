import SwiftUI
import MakoshTelegram

struct TelegramSharedMediaView: View {
    @ObservedObject var model: TelegramModel
    @ObservedObject private var search: TelegramSearchModel
    @StateObject private var actions = TelegramAttachmentActions()
    let profileContextID: UUID
    let openMessage: () -> Void
    @State private var selection: GallerySelection?
    private struct GallerySelection: Identifiable { let id: String }
    private static let filters: [TelegramSearchMediaFilter] = [.photoVideo, .files, .links, .music, .voiceOrVideo, .gifs]
    init(model: TelegramModel, profileContextID: UUID, openMessage: @escaping () -> Void) {
        self.model = model; search = model.sharedMedia; self.profileContextID = profileContextID; self.openMessage = openMessage
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 20) {
                    ForEach(Self.filters) { filter in
                        Button {
                            selection = nil; model.playback.stop(); actions.cancel(); search.mediaFilter = filter
                        } label: {
                            Text(filter.galleryTitle).fontWeight(search.mediaFilter == filter ? .semibold : .regular)
                                .foregroundStyle(search.mediaFilter == filter ? Color.accentColor : .secondary)
                                .padding(.vertical, 15).overlay(alignment: .bottom) {
                                    if search.mediaFilter == filter { Rectangle().fill(Color.accentColor).frame(height: 2) }
                                }
                        }.buttonStyle(.plain).accessibilityIdentifier("telegram.profile.media.\(filter.rawValue)")
                    }
                }.padding(.horizontal, 16)
            }.frame(height: 50)
            TextField("Поиск в общих медиа", text: $search.messageQuery).textFieldStyle(.roundedBorder).padding(12)
                .accessibilityIdentifier("telegram.profile.media.search")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if search.mediaFilter == .photoVideo {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                            ForEach(visualItems) { item in
                                TelegramVisualMediaView(attachment: item.attachment, contextID: search.resultContextID,
                                    media: model.media, actions: actions, playback: model.playback,
                                    identifierPrefix: "telegram.profile.media", openPhoto: { selection = .init(id: item.id) }) {
                                        Button("В переписке") { jump(item.message) }
                                    }.frame(height: 160).contextMenu {
                                        Button("Открыть галерею") { selection = .init(id: item.id) }
                                        Button("В переписке") { jump(item.message) }
                                    }
                            }
                        }
                    } else {
                        ForEach(search.messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                if !message.text.isEmpty {
                                    if message.actionMetadata?.canCopy == true { Text(message.text).textSelection(.enabled).lineLimit(6) }
                                    else { Text(message.text).lineLimit(6) }
                                }
                                ForEach(message.attachments) { attachment in
                                    TelegramAttachmentRow(attachment: attachment, contextID: search.resultContextID,
                                        hasCaption: !message.text.isEmpty, media: model.media, actions: actions, playback: model.playback) {
                                            Button("В переписке") { jump(message) }
                                        }
                                }
                                Button("В переписке") { jump(message) }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                    if search.messageStatus == .loading { ProgressView("Загрузка медиа…").frame(maxWidth: .infinity).padding() }
                    else if search.messageStatus == .failed || search.messageStatus == .timedOut {
                        Text(search.unavailableReason ?? "Не удалось загрузить медиа.").foregroundStyle(.secondary)
                        Button("Повторить", action: search.retryMessages)
                    } else if search.messages.isEmpty { Text("В этой категории пока нет медиа").foregroundStyle(.secondary).padding(24) }
                    if search.canLoadMoreMessages {
                        Button("Загрузить ещё", action: search.loadMoreMessages).frame(maxWidth: .infinity).padding()
                            .accessibilityIdentifier("telegram.profile.media.more")
                    }
                }.padding(4)
            }.accessibilityIdentifier("telegram.profile.media.collection")
            if let error = actions.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
            TelegramPlaybackView(playback: model.playback)
        }.sheet(item: $selection) { selection in
            TelegramSharedMediaViewer(items: visualItems, initialID: selection.id, contextID: search.resultContextID,
                media: model.media, playback: model.playback, actions: actions) { jump($0) }
        }.onDisappear { actions.cancel(); model.playback.stop() }
            .sheet(isPresented: Binding(get: { actions.preview != nil }, set: { if !$0 { actions.preview = nil } })) {
                VStack {
                    if let image = actions.preview { Image(decorative: image.image, scale: 1).resizable().scaledToFit().frame(maxWidth: 900, maxHeight: 650) }
                    Button("Закрыть предпросмотр") { actions.preview = nil }.keyboardShortcut(.cancelAction)
                }.padding(20)
            }
    }
    private var visualItems: [TelegramSharedMediaItem] {
        search.messages.flatMap { message in message.attachments.filter { $0.kind == .photo || $0.playback == .video }
            .map { .init(message: message, attachment: $0) } }
    }
    private func jump(_ message: TelegramMessage) {
        if model.openSharedMediaMessage(id: message.id, contextID: search.resultContextID, profileContextID: profileContextID) { openMessage() }
    }
}

private struct TelegramSharedMediaItem: Identifiable {
    let message: TelegramMessage
    let attachment: TelegramAttachment
    var id: String { attachment.id }
}

private struct TelegramSharedMediaViewer: View {
    @Environment(\.dismiss) private var dismiss
    let items: [TelegramSharedMediaItem]
    let initialID: String
    let contextID: UUID
    @ObservedObject var media: TelegramMediaController
    @ObservedObject var playback: TelegramPlaybackController
    @ObservedObject var actions: TelegramAttachmentActions
    let jump: (TelegramMessage) -> Void
    @State private var index = 0
    @State private var image: TelegramImagePreview?
    @State private var failed = false
    @State private var reveal = TelegramMediaRevealState()
    private struct Request: Equatable { let context: UUID; let id: String; let phase: TelegramMediaPhase; let url: URL?; let hidden: Bool }
    var body: some View {
        if items.indices.contains(index) {
            let item = items[index], key = TelegramMediaKey(attachmentID: item.attachment.id, purpose: .full)
            let hidden = reveal.isHidden(item.attachment, contextID: contextID)
            let request = Request(context: contextID, id: item.id, phase: media.phase(for: key), url: media.downloadedFile(for: key), hidden: hidden)
            VStack(spacing: 0) {
                HStack {
                    Text(item.attachment.name).lineLimit(1); Spacer()
                    Button("Закрыть галерею") { dismiss() }.keyboardShortcut(.cancelAction)
                }.padding(16)
                ZStack {
                    Color.black.opacity(0.9)
                    if hidden {
                        Button("Показать скрытое вложение") { reveal.reveal(item.attachment, contextID: contextID); load() }
                    } else if !item.attachment.canDownload { Text("Файл недоступен").foregroundStyle(.white) }
                    else if failed { Text("Не удалось открыть изображение").foregroundStyle(.white) }
                    else if request.phase == .failed || request.phase == .timedOut || request.phase == .cancelled || request.phase == .idle {
                        Button("Повторить загрузку") { load() }
                    } else if case .downloading = request.phase {
                        VStack { ProgressView().tint(.white); Button("Отменить загрузку") { media.cancel(key) } }
                    } else if let image { Image(decorative: image.image, scale: 1).resizable().scaledToFit().padding(8) }
                    else if item.attachment.playback != nil {
                        VStack {
                            Button("Воспроизвести") { playback.open(attachment: item.attachment, media: media) }.disabled(media.phase(for: key) != .ready)
                            TelegramPlaybackView(playback: playback)
                        }.padding(24).background(.regularMaterial)
                    } else if item.attachment.kind == .photo { ProgressView().tint(.white) }
                    else { Text("Просмотр этого файла недоступен. Его можно сохранить.").foregroundStyle(.white) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Button("Назад", systemImage: "chevron.left") { move(-1) }.disabled(index == 0)
                    Text("\(index + 1) / \(items.count)").monospacedDigit()
                    Button("Вперёд", systemImage: "chevron.right") { move(1) }.disabled(index + 1 == items.count)
                    Text(item.message.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    Spacer()
                    Button("Сохранить…") { actions.save(media: media, key: key, name: item.attachment.name) }.disabled(media.phase(for: key) != .ready || actions.isBusy)
                    Button("В переписке") { dismiss(); jump(item.message) }
                }.padding(16).frame(height: 95)
            }.frame(width: 900, height: 650)
                .task(id: request) {
                    image = nil; failed = false
                    guard request.phase == .ready, !request.hidden else { return }
                    guard item.attachment.kind == .photo else { return }
                    do {
                        let available = try await media.withDownloadedFile(for: key) { url, size in
                            let decoded = try await TelegramDownloadedFileIO.image(source: url, expectedSize: size)
                            try Task.checkCancellation(); image = decoded
                        }
                        if !available { failed = true }
                    } catch is CancellationError {} catch { failed = true }
                }
                .onChange(of: index) { _, _ in load() }
                .onAppear { index = items.firstIndex { $0.id == initialID } ?? 0; load() }
                .onDisappear { playback.stop() }
                .onKeyPress(.leftArrow) { if index > 0 { move(-1) }; return .handled }
                .onKeyPress(.rightArrow) { if index + 1 < items.count { move(1) }; return .handled }
        }
    }
    private func move(_ offset: Int) { playback.stop(); index += offset }
    private func load() {
        if items.indices.contains(index), !reveal.isHidden(items[index].attachment, contextID: contextID) {
            media.start(items[index].attachment, purpose: .full)
        }
    }
}

private extension TelegramSearchMediaFilter {
    var galleryTitle: String {
        switch self { case .photoVideo: "Медиа"; case .files: "Файлы"; case .links: "Ссылки"; case .music: "Музыка"; case .voiceOrVideo: "Голосовые"; case .gifs: "GIF"; default: "Все" }
    }
}
