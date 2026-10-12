import SwiftUI
import AppKit
import AVFoundation
import MakoshTelegram

/// The reference's300pt overlay and264pt circle leave the shared composer in control.
struct TelegramRoundVideoRecorderView: View {
    @ObservedObject var recording: TelegramVoiceRecordingController
    @ObservedObject var upload: TelegramUploadController
    let selectedChatID: Int64?
    let synthetic: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if recording.isActive, recording.selectedKind == .roundVideo {
            ZStack {
                Circle().fill(.black)
                if synthetic {
                    Circle().fill(AngularGradient(colors: [.blue, .purple, .cyan, .blue], center: .center))
                    VStack(spacing: 8) {
                        Image(systemName: "video.fill").font(.system(size: 44))
                        Text("Синтетическая камера").font(.caption)
                    }.foregroundStyle(.white)
                } else if let session = recording.previewSession {
                    RoundCameraPreview(session: session)
                }
                if !synthetic {
                    RoundVideoPlaceholder()
                        .opacity(recording.phase == .authorizing || recording.previewSession == nil ? 1 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 1), value: recording.previewSession == nil)
                }
                if recording.phase == .authorizing || recording.phase == .finishing { ProgressView().tint(.white) }
            }
            .frame(width: 264, height: 264).clipShape(Circle())
            .shadow(color: .black.opacity(0.35), radius: 12)
            .overlay {
                Circle().trim(from: 0, to: min(1, max(0, recording.duration / 60)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 281, height: 281)
            }
            .frame(width: 300, height: 300)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(synthetic ? "Синтетический предпросмотр круглого видео" : "Предпросмотр круглого видео")
            .accessibilityIdentifier("telegram.roundVideo.preview")
            .transition(.opacity)
        } else if upload.target?.chatID == selectedChatID, upload.phase == .ready,
                  upload.isRecordedRoundVideo, let contextID = upload.preparationContextID {
            PreparedRoundPreview(playback: upload.videoPlayback, file: upload.file)
                .shadow(color: .black.opacity(0.35), radius: 12)
                .frame(width: 300, height: 300)
                .task(id: contextID) { await upload.openRoundVideoPreview(contextID: contextID) }
                .onDisappear { upload.stopVideoPreview(contextID: contextID) }
                .id(contextID)
        }
    }
}

/// Independently drawn blurred placeholder: no reference image is bundled.
private struct RoundVideoPlaceholder: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.84, green: 0.76, blue: 0.63),
            Color(red: 0.65, green: 0.47, blue: 0.44), Color(red: 0.17, green: 0.15, blue: 0.21)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .leading) { Color(red: 0.98, green: 0.91, blue: 0.70).frame(width: 50).blur(radius: 40) }
            .accessibilityHidden(true)
    }
}

private struct PreparedRoundPreview: View {
    @ObservedObject var playback: TelegramUploadVideoPlaybackController
    let file: TelegramUploadFile?
    @State private var poster: TelegramImagePreview?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if let poster {
                Image(decorative: poster.image, scale: 1).resizable().scaledToFill()
                    .frame(width: 264, height: 264).clipped()
            } else { RoundVideoPlaceholder() }
            TelegramRoundVideoPlayerView(playback: playback)
                .opacity(playback.player != nil || playback.error != nil ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: playback.player != nil)
        }
        .frame(width: 264, height: 264).clipShape(Circle())
        .task(id: file?.id) {
            poster = nil
            // Capture the immutable owned preparation, never the picker URL.
            // The existing preview boundary validates its bytes and lifetime;
            // task cancellation prevents a retired stage publishing a poster.
            guard let file else { return }
            do {
                let preview = try await TelegramUploadFileIO.preview(file)
                guard !Task.isCancelled else { return }
                poster = preview
            } catch {
                // Playback supplies the visible failure state; keep the safe
                // placeholder when an already retired stage cannot be read.
            }
        }
    }
}

private struct RoundCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraView { CameraView(frame: .zero) }
    func updateNSView(_ view: CameraView, context: Context) {
        if view.preview.session !== session { view.preview.session = session }
        if let connection = view.preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
    static func dismantleNSView(_ view: CameraView, coordinator: ()) { view.preview.session = nil }
    final class CameraView: NSView {
        let preview = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) {
            super.init(frame: frame); wantsLayer = true
            layer?.masksToBounds = true
            preview.videoGravity = .resizeAspectFill; layer?.addSublayer(preview)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout(); preview.frame = bounds
            layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        }
    }
}
