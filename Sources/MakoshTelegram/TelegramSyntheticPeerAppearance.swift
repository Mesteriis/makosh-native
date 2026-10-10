#if DEBUG
import Foundation
import CoreGraphics
import ImageIO

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
    func cancel() {
        if let directory { try? FileManager.default.removeItem(at: directory); self.directory = nil }
    }
    isolated deinit { cancel() }
}
#endif
