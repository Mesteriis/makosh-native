import SwiftUI
import AVKit
import MakoshTelegram

struct TelegramPlaybackView: View {
    @ObservedObject var playback: TelegramPlaybackController
    @State private var seeking = false
    @State private var seekPosition = 0.0

    var body: some View {
        if let attachment = playback.attachment {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(attachment.name, systemImage: playback.hasVideo ? "video" : "waveform")
                        .font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button("Закрыть проигрыватель", action: playback.stop)
                        .accessibilityIdentifier("telegram.playback.close")
                }
                if playback.hasVideo, let player = playback.player {
                    TelegramNativePlayerView(player: player)
                        .frame(height: 180).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("telegram.playback.video")
                }
                if playback.canControl {
                    HStack(spacing: 12) {
                        Button(playback.phase == .playing || playback.phase == .buffering ? "Пауза" : "Воспроизвести",
                               action: playback.togglePlayback)
                            .accessibilityIdentifier("telegram.playback.toggle")
                        Slider(value: Binding(get: { seeking ? seekPosition : playback.position }, set: { seekPosition = $0 }),
                               in: 0...max(0.01, playback.duration), onEditingChanged: { editing in
                            if editing { seekPosition = playback.position; seeking = true }
                            else { seeking = false; playback.seek(seconds: seekPosition) }
                        }).accessibilityLabel("Позиция воспроизведения")
                            .accessibilityIdentifier("telegram.playback.seek")
                        Text(time(playback.position) + " / " + time(playback.duration))
                            .font(.caption.monospacedDigit()).accessibilityIdentifier("telegram.playback.time")
                        Picker("Скорость", selection: Binding(get: { playback.rate }, set: { playback.setRate($0) })) {
                            ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { rate in Text(String(format: "%g×", rate)).tag(rate) }
                        }.frame(width: 120).accessibilityIdentifier("telegram.playback.rate")
                    }
                }
                HStack(spacing: 8) {
                    if playback.phase == .preparing || playback.phase == .loading || playback.phase == .buffering {
                        ProgressView().controlSize(.mini)
                    }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("telegram.playback.status")
                }
                if let error = playback.error { Text(error).font(.callout).foregroundStyle(.red) }
            }.padding(12).background(.quaternary.opacity(0.4))
                .accessibilityIdentifier("telegram.playback")
        } else if let error = playback.error {
            HStack { Text(error); Spacer(); Button("Закрыть", action: playback.stop) }
                .font(.callout).padding(12).foregroundStyle(.red)
                .accessibilityIdentifier("telegram.playback.cleanupError")
        }
    }

    private var status: String {
        switch playback.phase {
        case .idle: "Проигрыватель закрыт"
        case .preparing: "Подготовка загруженного файла…"
        case .loading: "Открытие файла…"
        case .ready: "Готово к воспроизведению"
        case .playing: "Воспроизведение"
        case .paused: "Пауза"
        case .buffering: "Ожидание проигрывателя…"
        case .ended: "Воспроизведение завершено. Для повтора откройте файл снова."
        case .failed: "Не удалось воспроизвести"
        case .timedOut: "Подготовка заняла слишком много времени"
        }
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct TelegramNativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}
