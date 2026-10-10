import Foundation
import CryptoKit
import Postbox
import TelegramCore

public enum TelegramAttachmentKind: Sendable, Equatable {
    case photo, file, unsupported
}

public struct TelegramAttachment: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: TelegramAttachmentKind
    public let name: String
    public let byteCount: Int64?
    public let mimeType: String?
    public let hasPreview: Bool
    public let canDownload: Bool
}

/// A display/export suggestion only. Never use this value as a cache path or extension.
public func telegramAttachmentName(_ name: String?) -> String {
    let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
    let cleaned = String(String.UnicodeScalarView((name ?? "").unicodeScalars.filter { !forbidden.contains($0) }))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let bounded = String(cleaned.prefix(180))
    guard !bounded.isEmpty, bounded.unicodeScalars.contains(where: { $0 != "." && !CharacterSet.whitespaces.contains($0) }) else {
        return "Файл"
    }
    return bounded
}

struct TelegramAttachmentSource {
    let attachment: TelegramAttachment
    let full: MediaResourceReference?
    let preview: MediaResourceReference?
    let location: MediaResourceUserLocation
    let contentType: MediaResourceUserContentType
}

/// Pure projection: retains message references but performs no fetch, file or account access.
func telegramAttachments(_ message: Message) -> [TelegramAttachmentSource] {
    message.media.enumerated().map { ordinal, media in
        let reference = AnyMediaReference.message(message: MessageReference(message), media: media)
        let kind: TelegramAttachmentKind
        let name: String
        let size: Int64?
        let mimeType: String?
        let fullResource: MediaResource?
        let previewResource: MediaResource?
        let contentType: MediaResourceUserContentType
        if let image = media as? TelegramMediaImage {
            kind = .photo
            name = "Фотография"
            fullResource = largestImageRepresentation(image.representations)?.resource
            previewResource = smallestImageRepresentation(image.representations)?.resource
            size = fullResource?.size
            mimeType = nil
            contentType = .image
        } else if let file = media as? TelegramMediaFile {
            kind = .file
            name = telegramAttachmentName(file.fileName)
            fullResource = file.resource
            previewResource = smallestImageRepresentation(file.previewRepresentations)?.resource
            size = file.size
            mimeType = file.mimeType
            contentType = MediaResourceUserContentType(file: file)
        } else {
            // Paid/locked and unknown media are intentionally not recursively expanded.
            kind = .unsupported
            name = media is TelegramMediaPaidContent ? "Платное вложение не поддерживается" : "Вложение не поддерживается"
            fullResource = nil
            previewResource = nil
            size = nil
            mimeType = nil
            contentType = .other
        }
        func usable(_ resource: MediaResource?) -> MediaResourceReference? {
            guard let resource, !(resource is EmptyMediaResource) else { return nil }
            return reference.resourceReference(resource)
        }
        let full = usable(fullResource)
        let preview = usable(previewResource)
        // Resource identities remain opaque in the public descriptor; references/access hashes
        // never become UI IDs. Length framing avoids delimiter collisions in resource strings.
        let resourceKeys = [fullResource?.id.stringRepresentation ?? "", previewResource?.id.stringRepresentation ?? ""]
        let framed = resourceKeys.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
        let mediaKey = media.id.map { "\($0.namespace):\($0.id)" } ?? "none"
        let id = "\(message.id.peerId.toInt64()):\(message.id.namespace):\(message.id.id):\(ordinal):\(mediaKey):\(digest)"
        let attachment = TelegramAttachment(id: id, kind: kind, name: name,
            byteCount: size.flatMap { $0 >= 0 ? $0 : nil }, mimeType: mimeType,
            hasPreview: preview != nil, canDownload: full != nil)
        return TelegramAttachmentSource(attachment: attachment, full: full, preview: preview,
            location: .peer(message.id.peerId), contentType: contentType)
    }
}
