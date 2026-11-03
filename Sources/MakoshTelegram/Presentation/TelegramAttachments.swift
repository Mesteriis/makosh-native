import Foundation
import CryptoKit
import Postbox
import TelegramCore

public enum TelegramAttachmentKind: Sendable, Equatable {
    case photo, file, location, unsupported
}

public enum TelegramPlaybackKind: Sendable, Equatable {
    case voice, audio, video, roundVideo
}

public struct TelegramMediaDimensions: Sendable, Equatable {
    public let width: Int32
    public let height: Int32
    public init?(width: Int32, height: Int32) {
        guard width > 0, height > 0 else { return nil }
        self.width = width; self.height = height
    }
    public var aspectRatio: Double { Double(width) / Double(height) }
}

public struct TelegramAttachment: Identifiable, Sendable, Equatable {
    public let id: String
    public let kind: TelegramAttachmentKind
    public let name: String
    public let byteCount: Int64?
    public let mimeType: String?
    public let hasPreview: Bool
    public let canDownload: Bool
    public let playback: TelegramPlaybackKind?
    public let dimensions: TelegramMediaDimensions?
    public let isSpoiler: Bool
    public var paidMedia: TelegramPaidMediaState? = nil
    public var location: TelegramLocationAttachment? = nil

    public init(id: String, kind: TelegramAttachmentKind, name: String, byteCount: Int64?,
                mimeType: String?, hasPreview: Bool, canDownload: Bool,
                playback: TelegramPlaybackKind? = nil, dimensions: TelegramMediaDimensions? = nil, isSpoiler: Bool = false) {
        self.id = id
        self.kind = kind
        self.name = name
        self.byteCount = byteCount
        self.mimeType = mimeType
        self.hasPreview = hasPreview
        self.canDownload = canDownload
        self.playback = playback
        self.dimensions = dimensions
        self.isSpoiler = isSpoiler
    }
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
    let messageID: MessageId
    let full: MediaResourceReference?
    let preview: MediaResourceReference?
    let location: MediaResourceUserLocation
    let contentType: MediaResourceUserContentType
}

/// Classification is a capability hint from engine attributes, never a codec guarantee.
private func telegramPlaybackKind(_ attributes: [TelegramMediaFileAttribute]) -> TelegramPlaybackKind? {
    var hasVoice = false
    var hasAudio = false
    var videoKinds: [Bool] = []
    for attribute in attributes {
        switch attribute {
        case let .Audio(isVoice, _, _, _, _):
            if isVoice { hasVoice = true } else { hasAudio = true }
        case let .Video(_, _, flags, _, _, _):
            videoKinds.append(flags.contains(.instantRoundVideo))
        default:
            break
        }
    }
    // Contradictory voice/music or voice/video metadata must not promise playback.
    guard !(hasVoice && (hasAudio || !videoKinds.isEmpty)) else { return nil }
    if let round = videoKinds.first {
        guard videoKinds.allSatisfy({ $0 == round }) else { return nil }
        return round ? .roundVideo : .video
    }
    if hasVoice { return .voice }
    return hasAudio ? .audio : nil
}

/// Pure projection: retains message references but performs no fetch, file or account access.
func telegramAttachments(_ message: Message) -> [TelegramAttachmentSource] {
    message.media.enumerated().map { ordinal, media in
        let reference = AnyMediaReference.message(message: MessageReference(message), media: media)
        let kind: TelegramAttachmentKind
        let playback: TelegramPlaybackKind?
        let name: String
        let size: Int64?
        let mimeType: String?
        let fullResource: MediaResource?
        let previewResource: MediaResource?
        let contentType: MediaResourceUserContentType
        let dimensions: TelegramMediaDimensions?
        if let image = media as? TelegramMediaImage {
            kind = .photo
            playback = nil
            name = "Фотография"
            fullResource = largestImageRepresentation(image.representations)?.resource
            previewResource = smallestImageRepresentation(image.representations)?.resource
            size = fullResource?.size
            mimeType = nil
            contentType = .image
            dimensions = largestImageRepresentation(image.representations).flatMap {
                TelegramMediaDimensions(width: $0.dimensions.width, height: $0.dimensions.height)
            }
        } else if let file = media as? TelegramMediaFile {
            kind = .file
            playback = telegramPlaybackKind(file.attributes)
            name = telegramAttachmentName(file.fileName)
            fullResource = file.resource
            previewResource = smallestImageRepresentation(file.previewRepresentations)?.resource
            size = file.size
            mimeType = file.mimeType
            contentType = MediaResourceUserContentType(file: file)
            dimensions = file.attributes.compactMap { attribute -> TelegramMediaDimensions? in
                switch attribute {
                case let .Video(_, size, _, _, _, _), let .ImageSize(size):
                    return TelegramMediaDimensions(width: size.width, height: size.height)
                default: return nil
                }
            }.first
        } else if let map = media as? TelegramMediaMap, let location = TelegramLocationAttachment(map) {
            kind = .location
            playback = nil
            name = location.archiveDescription
            fullResource = nil; previewResource = nil; size = nil; mimeType = nil
            contentType = .other; dimensions = nil
        } else {
            // Paid/locked and unknown media are intentionally not recursively expanded.
            kind = .unsupported
            playback = nil
            name = media is TelegramMediaPaidContent ? "Платное вложение не поддерживается" : "Вложение не поддерживается"
            fullResource = nil
            previewResource = nil
            size = nil
            mimeType = nil
            contentType = .other
            dimensions = nil
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
        var attachment = TelegramAttachment(id: id, kind: kind, name: name,
            byteCount: size.flatMap { $0 >= 0 ? $0 : nil }, mimeType: mimeType,
            hasPreview: preview != nil, canDownload: full != nil, playback: playback, dimensions: dimensions,
            isSpoiler: message.attributes.contains { $0 is MediaSpoilerMessageAttribute })
        attachment.paidMedia = (media as? TelegramMediaPaidContent).flatMap(telegramPaidMediaState)
        attachment.location = (media as? TelegramMediaMap).flatMap(TelegramLocationAttachment.init)
        return TelegramAttachmentSource(attachment: attachment, messageID: message.id, full: full, preview: preview,
            location: .peer(message.id.peerId), contentType: contentType)
    }
}
