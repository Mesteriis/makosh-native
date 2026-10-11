import SwiftUI
import MakoshTelegram

/// Shared photo/video presentation; each surface supplies its message actions.
struct TelegramVisualMediaView<MenuContent: View>: View {
    let attachment: TelegramAttachment
    let contextID: UUID
    @ObservedObject var media: TelegramMediaController
    @ObservedObject var actions: TelegramAttachmentActions
    @ObservedObject var playback: TelegramPlaybackController
    var identifierPrefix = "telegram.album"
    var contentMode: ContentMode = .fill
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
                        Image(decorative: thumbnail.image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped().contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(actions.isBusy || playback.isBusy)
                        .accessibilityLabel("Посмотреть фото: " + attachment.name)
                        .accessibilityIdentifier(identifierPrefix + ".photo." + attachment.id)
                } else {
                    Image(decorative: thumbnail.image, scale: 1).resizable().aspectRatio(contentMode: contentMode)
                        .blur(radius: isHidden ? 18 : 0).accessibilityHidden(true)
                }
            } else {
                Image(systemName: attachment.playback == .video ? "video" : "photo").font(.largeTitle).foregroundStyle(.secondary)
            }
            if isHidden {
                Button { reveal.reveal(attachment, contextID: contextID) } label: {
                    Label(attachment.playback == .video ? "Показать скрытое видео" : "Показать скрытое фото", systemImage: "eye")
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.thinMaterial)
                }.buttonStyle(.plain).accessibilityIdentifier(identifierPrefix + ".reveal." + attachment.id)
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
                        .accessibilityIdentifier(identifierPrefix + ".preview." + attachment.id)
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
            .accessibilityElement(children: .contain).accessibilityIdentifier(identifierPrefix + ".tile." + attachment.id)
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
                .accessibilityLabel("Воспроизвести видео").accessibilityIdentifier(identifierPrefix + ".video." + attachment.id)
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
