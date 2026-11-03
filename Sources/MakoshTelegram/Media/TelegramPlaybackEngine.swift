import Foundation
import AVFoundation

struct TelegramPlaybackInfo: Equatable, Sendable {
    let duration: Double
    let hasVideo: Bool
}
enum TelegramPlaybackTransport: Equatable, Sendable { case playing, paused, waiting }
enum TelegramPlaybackEvent: Sendable {
    case transport(TelegramPlaybackTransport), position(Double), ended, failed
}

@MainActor
protocol TelegramPlaybackEngine: AnyObject {
    var player: AVPlayer? { get }
    func load(file: URL, kind: TelegramPlaybackKind,
              receive: @escaping @MainActor (TelegramPlaybackEvent) -> Void) async throws -> TelegramPlaybackInfo
    func play(rate: Float)
    func pause()
    func seek(seconds: Double)
    func setVolume(_ volume: Float)
    func stop()
}
