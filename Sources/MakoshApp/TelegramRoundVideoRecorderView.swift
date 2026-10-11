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
                if recording.phase == .authorizing || recording.phase == .finishing { ProgressView().tint(.white) }
            }
            .frame(width: 264, height: 264).clipShape(Circle())
            .overlay {
                Circle().trim(from: 0, to: min(1, max(0, recording.duration / 60)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 281, height: 281)
            }
            .frame(width: 300, height: 300)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(synthetic ? "Синтетический предпросмотр круглого видео" : "Предпросмотр круглого видео")
            .accessibilityIdentifier("telegram.roundVideo.preview")
        } else if upload.target?.chatID == selectedChatID, upload.phase == .ready,
                  upload.isRecordedRoundVideo, let contextID = upload.preparationContextID {
            TelegramRoundVideoPlayerView(playback: upload.videoPlayback)
                .frame(width: 300, height: 300)
                .task(id: contextID) { await upload.openRoundVideoPreview(contextID: contextID) }
                .onDisappear { upload.stopVideoPreview(contextID: contextID) }
                .id(contextID)
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
