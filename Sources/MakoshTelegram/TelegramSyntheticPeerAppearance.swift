#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import TelegramCore
import AVFoundation

func telegramSyntheticChatPresence(peerID: Int64, observedAt: Date) -> TelegramChatPresence? {
    let number = peerID % 10_000
    guard ![2, 3, 4, 5, 6, 7, 10, 11].contains(number) else { return nil }
    let now = Int32(observedAt.timeIntervalSince1970)
    let native: TelegramUserPresence
    if number == 9 { native = TelegramUserPresence(status: .recently(isHidden: true), lastActivity: now) }
    else { native = TelegramUserPresence(status: .present(until: now + (number == 8 ? 30 : (number == 12 || number == 13 ? -7200 : 3600))), lastActivity: 0) }
    return telegramChatPresence(presence: native, accountID: -1, peerID: peerID, serverTimeOffset: 0)
}

func telegramSyntheticPeerStatus(peerID: Int64) -> TelegramPeerStatus {
    let number = peerID % 10_000
    let kind: TelegramContactProfile.Kind = switch number {
    case 2: .group
    case 3, 6: .channel
    case 4, 7: .supergroup
    case 5: .bot
    default: .person
    }
    let presence: TelegramPeerStatus.Presence? = switch number {
    case 9: .recently(isHidden: true)
    case 10: nil
    case 12: .present(until: Int32(Date().timeIntervalSince1970) - 7_200)
    case 13: .present(until: Int32((Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()).timeIntervalSince1970))
    default: .present(until: Int32(Date().timeIntervalSince1970) + (number == 8 ? 4 : 3_600))
    }
    let count: Int? = switch number {
    case 2: 12
    case 3: 50_000
    case 4: 1_234
    case 7: 0
    default: nil
    }
    return TelegramPeerStatus(accountID: -1, peerID: peerID, kind: kind,
        presence: presence, memberCount: count, isSelf: number == 11)
}

@MainActor final class TelegramSyntheticAvatarProvider: TelegramAvatarProvider {
    func startVideo(key:TelegramAvatarKey,receive:@escaping @MainActor (TelegramAvatarVideoEvent)->Void) -> (any TelegramAvatarLease)? {
        let lease = SyntheticAvatarLease(),id = "synthetic-video-avatar-\(key.peerID)"
        receive(.resource(id,start:0))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-synthetic-avatar-video-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            lease.directory = directory
            lease.worker = Task { [weak lease] in
                do {
                    let url = directory.appendingPathComponent("owned-avatar.mp4")
                    try await syntheticAvatarVideo(url)
                    try Task.checkCancellation()
                    guard lease?.directory == directory else { return }
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                    let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    receive(.data(resourceID:id,url:url,size:Int64(size)))
                } catch { if !Task.isCancelled,lease?.directory == directory { receive(.failed(resourceID:id)) } }
            }
        } catch { receive(.failed(resourceID:id)) }
        return lease
    }
    func start(key: TelegramAvatarKey, receive: @escaping @MainActor (TelegramAvatarEvent) -> Void) -> any TelegramAvatarLease {
        let lease = SyntheticAvatarLease()
        guard key.peerID % 10_000 != 2 else { receive(.resource(nil)); return lease }
        let id = "synthetic-avatar-\(key.peerID)-\(key.size)"
        receive(.resource(id))
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-synthetic-avatar-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            lease.directory = directory
            let url = directory.appendingPathComponent("fixture")
            if key.peerID % 10_000 == 3 { try Data("corrupt synthetic avatar".utf8).write(to: url) }
            else {
                guard let context = CGContext(data: nil, width: 640, height: 640, bitsPerComponent: 8,
                    bytesPerRow: 2_560, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TelegramFileError.invalidImage }
                context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 640))
                context.setFillColor(CGColor(red: 1, green: 0.7, blue: 0.1, alpha: 1))
                context.fill(CGRect(x: 320, y: 0, width: 320, height: 640))
                guard let image = context.makeImage(),
                      let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw TelegramFileError.invalidImage }
                CGImageDestinationAddImage(output, image, nil)
                guard CGImageDestinationFinalize(output) else { throw TelegramFileError.invalidImage }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            receive(.data(resourceID: id, url: url, size: Int64(bytes)))
        } catch { receive(.failed(resourceID: id)) }
        return lease
    }
}

@MainActor private final class SyntheticAvatarLease: TelegramAvatarLease {
    var directory: URL?
    var worker: Task<Void,Never>?
    func cancel() {
        worker?.cancel(); worker = nil
        if let directory { try? FileManager.default.removeItem(at: directory); self.directory = nil }
    }
    isolated deinit { cancel() }
}
@MainActor private func syntheticAvatarVideo(_ url:URL) async throws {
    let writer = try AVAssetWriter(outputURL:url,fileType:.mp4)
    let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:64,AVVideoHeightKey:64])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:64,kCVPixelBufferHeightKey as String:64])
    writer.add(input)
    guard writer.startWriting() else { throw TelegramNativePlaybackError.unavailable }
    var complete = false; defer { if !complete { writer.cancelWriting() } }
    writer.startSession(atSourceTime:.zero)
    for frame in 0..<20 {
        try Task.checkCancellation()
        var waits = 0
        while !input.isReadyForMoreMediaData {
            guard waits < 500,writer.status == .writing else { throw TelegramNativePlaybackError.unavailable }
            try await Task.sleep(for:.milliseconds(10)); waits += 1
        }
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,64,64,kCVPixelFormatType_32ARGB,nil,&value) == kCVReturnSuccess,let value,
              CVPixelBufferLockBaseAddress(value,[]) == kCVReturnSuccess else { throw TelegramNativePlaybackError.unavailable }
        if let base = CVPixelBufferGetBaseAddress(value) {
            let row = CVPixelBufferGetBytesPerRow(value)
            for y in 0..<64 { for x in 0..<64 {
                let pixel = base.advanced(by:y*row+x*4).assumingMemoryBound(to:UInt8.self)
                pixel[0] = 255; pixel[1] = UInt8(frame*12); pixel[2] = x < 32 ? 80 : 200; pixel[3] = UInt8(255-frame*12)
            } }
        }
        CVPixelBufferUnlockBaseAddress(value,[])
        guard adaptor.append(value,withPresentationTime:CMTime(value:Int64(frame),timescale:10)) else { throw TelegramNativePlaybackError.unavailable }
    }
    input.markAsFinished(); writer.endSession(atSourceTime:CMTime(value:20,timescale:10))
    await writer.finishWriting(); try Task.checkCancellation()
    guard writer.status == .completed else { throw TelegramNativePlaybackError.unavailable }; complete = true
}
#endif
