import SwiftUI
import AppKit
import MakoshTelegram

struct TelegramAlbumHistoryRow<MenuContent: View>: View {
    let item: TelegramHistoryItem
    @ObservedObject var model: TelegramModel
    @ObservedObject var selection: TelegramMessageSelectionController
    @ObservedObject var media: TelegramMediaController
    @ObservedObject var actions: TelegramAttachmentActions
    @ObservedObject var playback: TelegramPlaybackController
    @ViewBuilder let menu: (TelegramMessage) -> MenuContent

    var body: some View {
        let context = model.messageActionContextID, window = model.historyWindowID
        let session = selection.session
        let sources = item.messages.compactMap { model.actionSource(for: $0) }
        let allSelected = sources.count == item.messages.count && sources.allSatisfy(selection.contains)
        let toggleGroup = {
            guard let window else { return }
            _ = model.toggleMessageGroupSelection(group: item, sessionID: session?.id, expectedRevision: session?.revision,
                contextID: context, windowID: window, extendingRange: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        }
        HStack(alignment: .center, spacing: 8) {
            if session != nil {
                Button(action: toggleGroup) {
                    Image(systemName: allSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(allSelected ? Color.accentColor : Color.secondary).frame(width: 24)
                }.buttonStyle(.plain).help("Выбрать или снять весь альбом")
                    .accessibilityLabel("Альбом, \(item.messages.count) сообщений")
                    .accessibilityValue(allSelected ? "Выбрано полностью" : "Не выбрано полностью")
                    .accessibilityIdentifier("telegram.selection.album." + item.id)
            }
            if item.messages.last?.isOutgoing == true { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 7) {
                if let first = item.messages.first {
                    if session != nil {
                        Button(action: toggleGroup) {
                            Text(first.author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }.buttonStyle(.plain).accessibilityLabel("Выбрать альбом, \(item.messages.count) сообщений")
                            .accessibilityIdentifier("telegram.album.author." + item.id)
                    } else {
                        Text(first.author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if item.isVisualAlbum {
                    TelegramAlbumMosaicLayout(aspects: item.messages.map { $0.attachments[0].dimensions?.aspectRatio ?? 1 }) {
                        ForEach(item.messages) { message in
                            let source = model.actionSource(for: message)
                            let selected = source.map(selection.contains) ?? false
                            Group {
                                if let session, let window {
                                    Button {
                                        _ = model.toggleMessageSelection(messageID: message.id, sessionID: session.id,
                                            contextID: context, windowID: window,
                                            extendingRange: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                                    } label: {
                                        ZStack(alignment: .bottomTrailing) {
                                            tile(message, context: context).allowsHitTesting(false).accessibilityHidden(true)
                                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                                .font(.title2).foregroundStyle(selected ? Color.accentColor : Color.white)
                                                .shadow(radius: 2).padding(7).accessibilityHidden(true)
                                        }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .disabled(!selected && (source.map { !TelegramComposerForwardSource(source: $0).isValid } ?? true))
                                        .accessibilityLabel(TelegramMessagePresentation.selectionLabel(for: message))
                                        .accessibilityValue(selected ? "Выбрано" : "Не выбрано")
                                        .accessibilityIdentifier("telegram.selection.message." + message.id)
                                        .contextMenu { menu(message) }
                                } else {
                                    tile(message, context: context)
                                }
                            }.background(TelegramHistoryReadRow(id: message.id, context: model.historyReadContext))
                                .id(message.id)
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 8))
                    if let message = item.messages.first(where: { !$0.text.isEmpty }) {
                        if session != nil {
                            Button(action: toggleGroup) {
                                TelegramMessageTextView(value: message.formattedTextForDisplay, identity: context.uuidString + message.id,
                                    canCopy: message.actionMetadata?.canCopy == true) { menu(message) }
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }.buttonStyle(.plain).accessibilityLabel("Выбрать альбом, \(item.messages.count) сообщений")
                                .accessibilityIdentifier("telegram.album.caption." + item.id)
                                .contextMenu { menu(message) }
                        } else {
                            TelegramMessageTextView(value: message.formattedTextForDisplay, identity: context.uuidString + message.id,
                                canCopy: message.actionMetadata?.canCopy == true) { menu(message) }
                        }
                    }
                } else {
                    ForEach(item.messages) { message in
                        TelegramSelectableHistoryRow(selection: selection, message: message, source: model.actionSource(for: message)) {
                            if let session, let window {
                                _ = model.toggleMessageSelection(messageID: message.id, sessionID: session.id,
                                    contextID: context, windowID: window,
                                    extendingRange: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
                            }
                        } content: {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(message.attachments) { attachment in
                                    TelegramAttachmentRow(attachment: attachment, media: media, actions: actions, playback: playback)
                                }
                                if !message.text.isEmpty {
                                    TelegramMessageTextView(value: message.formattedTextForDisplay, identity: context.uuidString + message.id,
                                        canCopy: message.actionMetadata?.canCopy == true) { menu(message) }
                                }
                            }.contextMenu { menu(message) }
                                .background(TelegramHistoryReadRow(id: message.id, context: model.historyReadContext))
                        }.id(message.id)
                    }
                }
                if let last = item.messages.last {
                    HStack {
                        Spacer(minLength: 0)
                        Button(action: toggleGroup) { TelegramMessageMetadataView(message: last) }.buttonStyle(.plain)
                            .help("Выбрать альбом").accessibilityLabel("Выбрать альбом, \(item.messages.count) сообщений")
                            .accessibilityIdentifier("telegram.album.select." + item.id)
                    }
                }
            }.frame(maxWidth: 420, alignment: .leading).padding(11)
                .background(item.messages.last?.isOutgoing == true ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 12))
            if item.messages.last?.isOutgoing != true { Spacer(minLength: 44) }
        }.background {
            if session != nil {
                Color.clear.contentShape(Rectangle()).onTapGesture(perform: toggleGroup)
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("telegram.album." + item.id)
    }

    private func tile(_ message: TelegramMessage, context: UUID) -> some View {
        TelegramAlbumTile(attachment: message.attachments[0], contextID: context, media: media, actions: actions, playback: playback) {
            menu(message)
        }
    }
}

private struct TelegramAlbumMosaicLayout: Layout {
    let aspects: [Double]
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(420, max(16, proposal.width ?? 360))
        let frames = TelegramAlbumMosaic.frames(aspects: aspects, width: width)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = TelegramAlbumMosaic.frames(aspects: aspects, width: bounds.width)
        for (view, frame) in zip(subviews, frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

private struct TelegramAlbumTile<MenuContent: View>: View {
    let attachment: TelegramAttachment
    let contextID: UUID
    @ObservedObject var media: TelegramMediaController
    @ObservedObject var actions: TelegramAttachmentActions
    @ObservedObject var playback: TelegramPlaybackController
    @ViewBuilder let menu: () -> MenuContent
    @State private var thumbnail: TelegramImagePreview?
    @State private var decodeFailed = false
    @State private var reveal = TelegramMediaRevealState()

    private var key: TelegramMediaKey {
        let full = TelegramMediaKey(attachmentID: attachment.id, purpose: .full)
        return attachment.kind == .photo && media.phase(for: full) == .ready ? full :
            .init(attachmentID: attachment.id, purpose: attachment.hasPreview ? .preview : .full)
    }
    private struct DecodeRequest: Equatable {
        let context: UUID, attachment: TelegramAttachment, key: TelegramMediaKey
        let phase: TelegramMediaPhase
        let url: URL?
    }
    var body: some View {
        let key = key, phase = media.phase(for: key)
        let isHidden = reveal.isHidden(attachment, contextID: contextID)
        let request = DecodeRequest(context: contextID, attachment: attachment, key: key, phase: phase, url: media.downloadedFile(for: key))
        ZStack {
            Color.secondary.opacity(0.15)
            if let thumbnail {
                if attachment.kind == .photo, !isHidden {
                    Button { actions.showPreview(media: media, key: key) } label: {
                        Image(decorative: thumbnail.image, scale: 1).resizable().scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(actions.isBusy || playback.isBusy)
                        .accessibilityLabel("Посмотреть фото: " + attachment.name)
                        .accessibilityIdentifier("telegram.album.photo." + attachment.id)
                } else {
                    Image(decorative: thumbnail.image, scale: 1).resizable().scaledToFill()
                        .blur(radius: isHidden ? 18 : 0).accessibilityHidden(true)
                }
            } else {
                Image(systemName: attachment.playback == .video ? "video" : "photo").font(.largeTitle).foregroundStyle(.secondary)
            }
            if isHidden {
                Button { reveal.reveal(attachment, contextID: contextID) } label: {
                    Label(attachment.playback == .video ? "Показать скрытое видео" : "Показать скрытое фото", systemImage: "eye")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.thinMaterial)
                }.buttonStyle(.plain).accessibilityIdentifier("telegram.album.reveal." + attachment.id)
            } else if attachment.playback == .video, !attachment.hasPreview {
                videoControl
            } else {
                switch phase {
                case .ready:
                    if decodeFailed {
                        Image(systemName: "exclamationmark.triangle").help("Превью недоступно. Файл можно сохранить через контекстное меню.")
                    } else if thumbnail == nil { ProgressView().controlSize(.small) }
                    else if attachment.playback == .video { videoControl }
                case .downloading:
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Button("Отменить") { media.cancel(key) }.controlSize(.small)
                    }
                case .idle, .cancelled, .failed, .timedOut:
                    Button { media.start(attachment, purpose: key.purpose) } label: {
                        Image(systemName: "arrow.down.circle.fill").font(.largeTitle)
                    }.buttonStyle(.plain).help(phase == .idle ? "Загрузить превью" : "Повторить загрузку")
                        .accessibilityLabel("Загрузить превью: " + attachment.name)
                        .accessibilityIdentifier("telegram.album.preview." + attachment.id)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped().contentShape(Rectangle())
            .contextMenu {
                menu()
                Divider()
                if !isHidden, phase == .ready, thumbnail != nil {
                    Button("Посмотреть превью") { actions.showPreview(media: media, key: key) }.disabled(actions.isBusy || playback.isBusy)
                }
                fullFileActions(isHidden: isHidden)
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("telegram.album.tile." + attachment.id)
            .task(id: request) {
                thumbnail = nil; decodeFailed = false
                guard phase == .ready, attachment.kind == .photo || key.purpose == .preview else { return }
                do {
                    let available = try await media.withDownloadedFile(for: key) { url, size in
                        let decoded = try await TelegramDownloadedFileIO.thumbnail(source: url, expectedSize: size)
                        try Task.checkCancellation()
                        guard media.phase(for: key) == .ready, media.downloadedFile(for: key) == request.url else { return }
                        thumbnail = decoded
                    }
                    if !available { decodeFailed = true }
                } catch is CancellationError { }
                catch { if !Task.isCancelled { decodeFailed = true } }
            }
    }

    @ViewBuilder private var videoControl: some View {
        let full = TelegramMediaKey(attachmentID: attachment.id, purpose: .full)
        if case .downloading = media.phase(for: full) {
            VStack { ProgressView().controlSize(.small); Button("Отменить") { media.cancel(full) } }
        } else {
            Button {
                if media.phase(for: full) == .ready { playback.open(attachment: attachment, media: media) }
                else { media.start(attachment, purpose: .full) }
            } label: { Image(systemName: "play.circle.fill").font(.largeTitle) }
                .buttonStyle(.plain).disabled(actions.isBusy || playback.isBusy)
                .accessibilityLabel("Воспроизвести видео").accessibilityIdentifier("telegram.album.video." + attachment.id)
        }
    }
    @ViewBuilder private func fullFileActions(isHidden: Bool) -> some View {
        let full = TelegramMediaKey(attachmentID: attachment.id, purpose: .full)
        switch media.phase(for: full) {
        case .ready:
            Button("Сохранить файл…") { actions.save(media: media, key: full, name: attachment.name) }.disabled(actions.isBusy || playback.isBusy)
            if !isHidden, attachment.playback != nil {
                Button("Открыть проигрыватель") { playback.open(attachment: attachment, media: media) }.disabled(actions.isBusy || playback.isBusy)
            }
        case .downloading:
            Button("Отменить загрузку файла") { media.cancel(full) }
        default:
            if attachment.canDownload { Button("Загрузить файл") { media.start(attachment, purpose: .full) } }
        }
    }
}
