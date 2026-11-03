#if DEBUG
import Foundation

func telegramSyntheticAlbumDimensions(_ number: Int) -> TelegramMediaDimensions {
    if number == 126 { return .init(width: 160, height: 320)! }
    if (122...128).contains(number) { return .init(width: 320, height: 320)! }
    return .init(width: 320, height: 200)!
}

/// Explicit album QA only; the default synthetic fixture stays unchanged.
func telegramSyntheticAlbumMessage(_ original: TelegramMessage) -> TelegramMessage {
    guard let metadata = original.actionMetadata else { return original }
    let number = Int(metadata.messageID)
    let groups: [(ClosedRange<Int>, UInt32)] = [(80...81, 1), (115...116, 2), (119...120, 3),
        (122...125, 4), (126...128, 5), (129...130, 6)]
    guard let group = groups.first(where: { $0.0.contains(number) })?.1 else { return original }
    let files = (119...120).contains(number), video = (115...116).contains(number)
    let kind = files ? "file" : video ? "video" : "photo"
    var message = TelegramMessage(id: original.id, date: original.date, text: original.text,
        author: "Синтетический альбом", isOutgoing: false, delivery: .none)
    message.albumGroupID = group; message.nativeGroupingKey = Int64(group)
    message.captionAboveMedia = number == 126 || number == 129
    message.attachments = [.init(id: "synthetic-album-\(kind):\(metadata.peerID):\(number)", kind: files || video ? .file : .photo,
        name: "Синтетическое вложение \(number)." + (files ? "txt" : video ? "mp4" : "png"),
        byteCount: nil, mimeType: files ? "text/plain" : video ? "video/mp4" : "image/png",
        hasPreview: !files, canDownload: true, playback: video ? .video : nil,
        dimensions: files ? nil : telegramSyntheticAlbumDimensions(number), isSpoiler: number == 129)]
    message.actionMetadata = .init(peerID: metadata.peerID, namespace: metadata.namespace, messageID: metadata.messageID,
        fingerprint: metadata.fingerprint + "-album", text: metadata.text, authorID: 999,
        canReply: true, canEdit: false, canForward: metadata.canForward, canDeleteLocally: true,
        canDeleteForEveryone: false, allowsEmptyEdit: true, editLimit: 1024, formattedText: metadata.formattedText,
        canCopy: metadata.canCopy)
    return message
}
#endif
