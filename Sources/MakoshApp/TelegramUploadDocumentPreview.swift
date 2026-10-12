import SwiftUI
import MakoshTelegram

struct TelegramUploadDocumentPreview: View {
    let file: TelegramUploadFile
    var isActive = true
    @State private var preview: TelegramUploadDocumentPreviewSnapshot?
    @State private var failed = false
    @State private var playTask: Task<Void, Never>?
    @StateObject private var playback = TelegramUploadDocumentAudioPlaybackController()
    private struct LoadID: Equatable { let file: TelegramUploadFile; let active: Bool }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let preview {
                TelegramUploadDocumentPreviewContent(preview: preview,
                    isPlaying: playback.phase == .playing || playback.phase == .buffering,
                    playEnabled: isActive && playback.phase != .loading, onPlay: play)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill").font(.title2).frame(width: 40, height: 40).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(height: 40)
            }
            if failed { Label("Предпросмотр недоступен", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("telegram.upload.document." + file.id.uuidString.lowercased())
        .task(id: LoadID(file: file, active: isActive)) {
            playTask?.cancel(); playTask = nil; playback.stop()
            guard isActive else { return }
            preview = nil; failed = false
            do {
                let result = try await TelegramUploadDocumentPreviewIO.preview(file)
                guard !Task.isCancelled else { return }; preview = result
            } catch { if !Task.isCancelled { failed = true } }
        }
        .onDisappear { playTask?.cancel(); playTask = nil; playback.stop() }
    }

    private func play() {
        guard isActive, preview?.kind == .music else { return }
        if playback.canControl { playback.toggle(); return }
        playTask?.cancel()
        playTask = Task {
            await playback.load(file)
            guard !Task.isCancelled else { return }
            playback.toggle()
        }
    }
}

struct TelegramUploadDocumentPreviewContent: View {
    let preview: TelegramUploadDocumentPreviewSnapshot
    let isPlaying: Bool
    let playEnabled: Bool
    let onPlay: () -> Void
    var body: some View {
        Group {
            if preview.kind == .sticker, let image = preview.image?.image {
                let scale = 208 / CGFloat(max(image.width, image.height))
                Image(image, scale: 1, label: Text(preview.title)).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: max(40, CGFloat(image.width) * scale), height: max(40, CGFloat(image.height) * scale))
                    .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    if preview.kind == .music {
                        Button(action: onPlay) {
                            ZStack {
                                Circle().fill(Color.accentColor)
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill").foregroundStyle(.white)
                            }.frame(width: 40, height: 40)
                        }.buttonStyle(.plain).disabled(!playEnabled)
                            .accessibilityLabel(isPlaying ? "Приостановить предпросмотр аудио" : "Воспроизвести предпросмотр аудио")
                            .accessibilityIdentifier("telegram.upload.document.play")
                    } else if preview.kind == .graphic, let image = preview.image?.image {
                        Image(image, scale: 1, label: Text(preview.title)).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 70, height: 70).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "doc.fill").font(.title2).foregroundStyle(.secondary).frame(width: 40, height: 40)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preview.title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                        Text(preview.subtitle).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.frame(height: preview.kind == .graphic ? 70 : 40)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
