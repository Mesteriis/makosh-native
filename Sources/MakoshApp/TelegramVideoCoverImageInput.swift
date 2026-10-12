import AppKit
import ImageIO
import MakoshTelegram

@MainActor enum TelegramVideoCoverImageInput {
    enum Input { case files([URL]), bytes(Data) }
    /// Called only by an explicit Paste action in this editor.
    static func pasteboard() throws -> Input {
        let pasteboard = NSPasteboard.general
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            guard urls.count <= 16 else { throw TelegramUploadFileError.invalidImage }
            return .files(urls)
        }
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else { throw TelegramUploadFileError.tooLarge }
            return .bytes(data)
        }
        throw TelegramUploadFileError.invalidImage
    }
    static func adding(_ input: Input, to images: TelegramUploadVideoCoverImages,
                       canvasSize: CGSize, imageSize: CGSize) async throws -> TelegramUploadVideoCoverImages {
        var admission = images
        var previews: [TelegramImagePreview] = []
        func append(_ source: URL) async throws {
            let selection = try await TelegramUploadVideoCoverIO.openSelection(source)
            defer { try? TelegramUploadVideoCoverIO.discardSelection(selection) }
            try Task.checkCancellation()
            // Admit each decode before retaining the next one, bounding peak
            // memory for multi-file paste; the accepted batch has one undo step.
            try admission.append(selection.preview, canvasSize: canvasSize, imageSize: imageSize)
            previews.append(selection.preview)
        }
        switch input {
        case let .files(urls):
            guard !urls.isEmpty, urls.count <= 16 else { throw TelegramUploadFileError.invalidImage }
            for url in urls { try await append(url) }
        case let .bytes(data):
            guard !data.isEmpty, data.count <= 20 * 1024 * 1024 else { throw TelegramUploadFileError.tooLarge }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-cover-paste-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = directory.appendingPathComponent("image")
            try data.write(to: source, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
            try await append(source)
        }
        try Task.checkCancellation()
        var result = images
        try result.append(previews, canvasSize: canvasSize, imageSize: imageSize)
        return result
    }
    static func copy(_ item: TelegramUploadVideoCoverImages.Item) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw TelegramUploadFileError.invalidImage }
        CGImageDestinationAddImage(destination, item.image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 20 * 1024 * 1024 else { throw TelegramUploadFileError.tooLarge }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setData(data as Data, forType: .png) else { throw TelegramUploadFileError.unavailable }
    }
}
