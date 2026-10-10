#if DEBUG
import Foundation
import CoreGraphics
import ImageIO

@MainActor final class TelegramSyntheticProfilePhotoProvider: TelegramProfilePhotoProvider {
    func load(peerID: Int64, receive: @escaping @MainActor ([TelegramProfilePhoto]) -> Void) -> any TelegramProfilePhotoSession {
        let photos = peerID % 10_000 == 2 ? [] : (0..<3).map { index in
            TelegramProfilePhoto(id: "qa-profile-\(peerID)-\(index)", date: 1_700_000_000 + Int32(index * 60),
                totalCount: 5, hasVideo: index == 1)
        }
        let session = SyntheticProfilePhotoSession(photos: photos)
        receive(photos)
        return session
    }
}

@MainActor private final class SyntheticProfilePhotoSession: TelegramProfilePhotoSession {
    let photos: [TelegramProfilePhoto]
    private var attempts: [String: Int] = [:]
    private var current: SyntheticProfilePhotoLease?
    private var cancelled = false
    init(photos: [TelegramProfilePhoto]) { self.photos = photos }
    func image(photoID: String, receive: @escaping @MainActor (TelegramProfilePhotoImageEvent) -> Void) -> any TelegramAvatarLease {
        current?.cancel()
        let lease = SyntheticProfilePhotoLease(); current = lease
        guard !cancelled, let index = photos.firstIndex(where: { $0.id == photoID }) else { receive(.failed); return lease }
        attempts[photoID, default: 0] += 1
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-synthetic-profile-photo-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            lease.directory = directory
            let url = directory.appendingPathComponent("fixture")
            if index == 2, attempts[photoID] == 1 { try Data("corrupt gallery fixture".utf8).write(to: url) }
            else {
                guard let context = CGContext(data: nil, width: 900, height: 640, bitsPerComponent: 8,
                    bytesPerRow: 3_600, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TelegramFileError.invalidImage }
                let colors = [CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1),
                    CGColor(red: 0.1, green: 0.7, blue: 0.3, alpha: 1), CGColor(red: 0.7, green: 0.2, blue: 0.8, alpha: 1)]
                context.setFillColor(colors[index]); context.fill(CGRect(x: 0, y: 0, width: 900, height: 640))
                context.setFillColor(CGColor(red: 1, green: 0.7, blue: 0.1, alpha: 1))
                context.fill(CGRect(x: 450, y: 0, width: 450, height: 640))
                guard let image = context.makeImage(),
                      let output = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw TelegramFileError.invalidImage }
                CGImageDestinationAddImage(output, image, nil)
                guard CGImageDestinationFinalize(output) else { throw TelegramFileError.invalidImage }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            receive(.data(url: url, size: Int64(count)))
        } catch { receive(.failed) }
        return lease
    }
    func cancel() { cancelled = true; current?.cancel(); current = nil }
    isolated deinit { cancel() }
}

@MainActor private final class SyntheticProfilePhotoLease: TelegramAvatarLease {
    var directory: URL?
    func cancel() {
        if let directory { try? FileManager.default.removeItem(at: directory); self.directory = nil }
    }
    isolated deinit { cancel() }
}
#endif
