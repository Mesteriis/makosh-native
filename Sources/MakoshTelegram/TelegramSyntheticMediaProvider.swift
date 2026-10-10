#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// In-memory QA never connects. Temporary fixture bytes are made only on Start.
@MainActor
final class TelegramSyntheticMediaProvider: TelegramMediaProvider {
    func start(attachmentID: String, purpose: TelegramMediaPurpose,
               receive: @escaping @MainActor (TelegramMediaEvent) -> Void) -> any TelegramMediaLease {
        let lease = SyntheticMediaLease()
        lease.task = Task { [weak lease] in
            do {
                for progress in [0.0, 0.3, 0.7] {
                    receive(.progress(progress))
                    try await Task.sleep(for: .milliseconds(600))
                }
                try Task.checkCancellation()
                guard let lease else { return }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-synthetic-media-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                lease.directory = directory
                let file = directory.appendingPathComponent("fixture")
                if purpose == .preview || attachmentID.hasSuffix(":130") {
                    let width = 320, height = 200
                    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw TelegramFileError.invalidImage }
                    context.setFillColor(CGColor(red: 0.12, green: 0.45, blue: 0.8, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    context.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1))
                    context.fillEllipse(in: CGRect(x: 110, y: 50, width: 100, height: 100))
                    guard let image = context.makeImage(),
                          let output = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw TelegramFileError.invalidImage }
                    CGImageDestinationAddImage(output, image, nil)
                    guard CGImageDestinationFinalize(output) else { throw TelegramFileError.invalidImage }
                } else {
                    try Data("Makosh synthetic attachment QA\nNo account or network data.\n".utf8).write(to: file)
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                receive(.data(file, offset: 0, size: Int64(size), complete: true))
            } catch is CancellationError { /* Owner cancellation already changed the phase. */ }
            catch { receive(.failed) }
        }
        return lease
    }
}

@MainActor
private final class SyntheticMediaLease: TelegramMediaLease {
    var task: Task<Void, Never>?
    var directory: URL?
    func cancel() {
        task?.cancel(); task = nil
        if let directory { try? FileManager.default.removeItem(at: directory); self.directory = nil }
    }
    isolated deinit { cancel() }
}
#endif
