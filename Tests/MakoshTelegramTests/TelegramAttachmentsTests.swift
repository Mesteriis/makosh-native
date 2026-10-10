import XCTest
import Postbox
import TelegramCore
@testable import MakoshTelegram

final class TelegramAttachmentsTests: XCTestCase {
    private func message(_ media: [Media], id: Int32 = 1, peer: Int64 = 100) -> Message {
        let peerID = PeerId(namespace: Namespaces.Peer.CloudGroup, id: ._internalFromInt64Value(peer))
        let group = TelegramGroup(id: peerID, title: "Synthetic group", photo: [], participantCount: 2,
            role: .member, membership: .Member, flags: [], defaultBannedRights: nil,
            migrationReference: nil, creationDate: 0, version: 0)
        return Message(stableId: 1, stableVersion: 0, id: MessageId(peerId: peerID, namespace: Namespaces.Message.Cloud, id: id),
            globallyUniqueId: nil, groupingKey: nil, groupInfo: nil, threadId: nil, timestamp: 1,
            flags: [], tags: [], globalTags: [], localTags: [], customTags: [], forwardInfo: nil,
            author: nil, text: "", attributes: [], media: media, peers: SimpleDictionary([peerID: group as Peer]),
            associatedMessages: SimpleDictionary(), associatedMessageIds: [], associatedMedia: [:],
            associatedThreadInfo: nil, associatedStories: [:])
    }

    private func representation(_ id: Int64, side: Int32) -> TelegramMediaImageRepresentation {
        TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: side, height: side),
            resource: LocalFileMediaResource(fileId: id, size: Int64(side)),
            progressiveSizes: [], immediateThumbnailData: nil)
    }

    private func photo(_ representations: [TelegramMediaImageRepresentation]) -> TelegramMediaImage {
        TelegramMediaImage(imageId: MediaId(namespace: 0, id: 40), representations: representations,
            immediateThumbnailData: nil, reference: nil, partialReference: nil, flags: [])
    }

    private func file(resource: TelegramMediaResource, name: String = "report.pdf",
                      previews: [TelegramMediaImageRepresentation] = [], size: Int64? = 500,
                      mimeType: String = "application/pdf", attributes: [TelegramMediaFileAttribute] = []) -> TelegramMediaFile {
        TelegramMediaFile(fileId: MediaId(namespace: 0, id: 50), partialReference: nil,
            resource: resource, previewRepresentations: previews, videoThumbnails: [],
            immediateThumbnailData: nil, mimeType: mimeType, size: size,
            attributes: [.FileName(fileName: name)] + attributes, alternativeRepresentations: [])
    }

    func testPhotoSelectsLargestAndSmallestWithoutDependingOnArrayOrder() throws {
        let large = representation(3, side: 1000)
        let small = representation(1, side: 40)
        let medium = representation(2, side: 400)
        let source = try XCTUnwrap(telegramAttachments(message([photo([medium, large, small])])).first)
        XCTAssertEqual(source.attachment.kind, .photo)
        XCTAssertEqual(source.full?.resource.id, large.resource.id)
        XCTAssertEqual(source.preview?.resource.id, small.resource.id)
        XCTAssertTrue(source.attachment.canDownload)
        XCTAssertTrue(source.attachment.hasPreview)
        XCTAssertEqual(source.attachment.byteCount, 1000)
        if let full = source.full, case let .media(.message(reference, _), _) = full {
            XCTAssertEqual(reference.id, message([]).id)
        } else { XCTFail("Full resource must retain message provenance") }
    }

    func testFileUsesFullResourceAndSeparateThumbnail() throws {
        let full = LocalFileMediaResource(fileId: 90, size: 500)
        let thumb = representation(91, side: 40)
        let source = try XCTUnwrap(telegramAttachments(message([file(resource: full, previews: [thumb])])).first)
        XCTAssertEqual(source.full?.resource.id, full.id)
        XCTAssertEqual(source.preview?.resource.id, thumb.resource.id)
        XCTAssertEqual(source.attachment.kind, .file)
        XCTAssertEqual(source.attachment.name, "report.pdf")
        XCTAssertEqual(source.attachment.mimeType, "application/pdf")
        XCTAssertEqual(source.attachment.byteCount, 500)
    }

    func testEmptyPhotoAndEmptyFileResourceAreNotDownloadable() {
        let sources = telegramAttachments(message([photo([]), file(resource: EmptyMediaResource(), size: -1)]))
        XCTAssertEqual(sources.count, 2)
        for source in sources {
            XCTAssertFalse(source.attachment.canDownload)
            XCTAssertFalse(source.attachment.hasPreview)
            XCTAssertNil(source.full)
            XCTAssertNil(source.preview)
        }
        XCTAssertNil(sources[1].attachment.byteCount)
    }

    func testPaidAndUnknownMediaDoNotExposeNestedDownloadResources() {
        let paid = TelegramMediaPaidContent(amount: 100, extendedMedia: [.full(media: photo([representation(1, side: 40)]))])
        let sources = telegramAttachments(message([paid, TelegramMediaUnsupported()]))
        XCTAssertEqual(sources.count, 2)
        for source in sources {
            XCTAssertEqual(source.attachment.kind, .unsupported)
            XCTAssertFalse(source.attachment.canDownload)
            XCTAssertNil(source.full)
            XCTAssertNil(source.preview)
            XCTAssertNil(source.attachment.playback)
        }
    }

    func testIdentityStableAndSeparatesMessagesOrdinalsAndChangedResource() {
        let item = file(resource: LocalFileMediaResource(fileId: 90))
        let first = telegramAttachments(message([item]))[0].attachment
        XCTAssertEqual(first, telegramAttachments(message([item]))[0].attachment)
        XCTAssertNotEqual(first.id, telegramAttachments(message([item], id: 2))[0].attachment.id)
        XCTAssertNotEqual(first.id, telegramAttachments(message([item], peer: 200))[0].attachment.id)
        let duplicates = telegramAttachments(message([item, item]))
        XCTAssertNotEqual(duplicates[0].attachment.id, duplicates[1].attachment.id)
        let changed = file(resource: LocalFileMediaResource(fileId: 91))
        XCTAssertNotEqual(first.id, telegramAttachments(message([changed]))[0].attachment.id)
        XCTAssertFalse(first.id.contains(item.resource.id.stringRepresentation))
    }

    func testCloudCredentialsAreNotPublicIdentityAndRevalidationKeepsIdentity() {
        func cloud(_ accessHash: Int64, reference: Data) -> TelegramMediaFile {
            file(resource: CloudDocumentMediaResource(datacenterId: 2, fileId: 900,
                accessHash: accessHash, size: 500, fileReference: reference, fileName: "report.pdf"))
        }
        let first = telegramAttachments(message([cloud(777_123_456, reference: Data([1, 2, 3]))]))[0]
        let refreshed = telegramAttachments(message([cloud(888_987_654, reference: Data([4, 5, 6]))]))[0]
        XCTAssertEqual(first.attachment.id, refreshed.attachment.id)
        XCTAssertFalse(first.attachment.id.contains("777123456"))
        XCTAssertFalse(refreshed.attachment.id.contains("888987654"))
    }

    func testHostileFilenameIsOnlyASanitizedLabel() {
        for name in [nil, "", "..", ". .", "\n\u{0}/\\:"] as [String?] {
            XCTAssertEqual(telegramAttachmentName(name), "Файл")
        }
        let source = telegramAttachments(message([file(resource: LocalFileMediaResource(fileId: 1), name: "../../bad\\name:\n.pdf")]))[0]
        XCTAssertFalse(source.attachment.name.contains("/"))
        XCTAssertFalse(source.attachment.name.contains("\\"))
        XCTAssertFalse(source.attachment.name.contains(":"))
        XCTAssertFalse(source.attachment.name.contains("\n"))
        XCTAssertEqual(telegramAttachmentName(String(repeating: "a", count: 1000)).count, 180)
        XCTAssertEqual(telegramAttachmentName(String(repeating: ".", count: 180) + "a"), "Файл")
        XCTAssertEqual(source.full?.resource.id, LocalFileMediaResource(fileId: 1).id)
    }

    func testPlaybackClassificationUsesActualAttributesAndVideoPrecedence() {
        let voice = TelegramMediaFileAttribute.Audio(isVoice: true, duration: 3, title: nil, performer: nil, waveform: nil)
        let music = TelegramMediaFileAttribute.Audio(isVoice: false, duration: 3, title: "Song", performer: "Artist", waveform: nil)
        let video = TelegramMediaFileAttribute.Video(duration: 3, size: PixelDimensions(width: 320, height: 240),
            flags: [.supportsStreaming], preloadSize: nil, coverTime: nil, videoCodec: nil)
        let round = TelegramMediaFileAttribute.Video(duration: 3, size: PixelDimensions(width: 240, height: 240),
            flags: [.instantRoundVideo], preloadSize: nil, coverTime: nil, videoCodec: nil)
        let cases: [([TelegramMediaFileAttribute], TelegramPlaybackKind?)] = [
            ([voice], .voice), ([music], .audio), ([video], .video), ([round], .roundVideo),
            ([music, video], .video), ([round, music], .roundVideo),
            ([voice, music], nil), ([music, voice], nil), ([voice, video], nil),
            ([round, voice], nil), ([round, video], nil), ([], nil)
        ]
        for (attributes, expected) in cases {
            let resource = LocalFileMediaResource(fileId: 701, size: 500)
            let source = telegramAttachments(message([file(resource: resource, attributes: attributes)]))[0]
            XCTAssertEqual(source.attachment.playback, expected)
            XCTAssertTrue(source.attachment.canDownload)
            XCTAssertEqual(source.full?.resource.id, resource.id)
            XCTAssertEqual(source.attachment.name, "report.pdf")
        }
    }

    func testMIMEAndExtensionDoNotGrantPlaybackOrChangeResourceIdentity() {
        let resource = LocalFileMediaResource(fileId: 702)
        for label in ["audio/ogg", "audio/mpeg", "video/mp4"] {
            let descriptor = telegramAttachments(message([file(resource: resource, name: "voice.mp4", mimeType: label)]))[0].attachment
            XCTAssertNil(descriptor.playback)
        }
        let plain = telegramAttachments(message([file(resource: resource)]))[0].attachment
        let audio = telegramAttachments(message([file(resource: resource,
            attributes: [.Audio(isVoice: true, duration: 1, title: nil, performer: nil, waveform: nil)])]))[0].attachment
        XCTAssertEqual(plain.id, audio.id)
        XCTAssertNotEqual(plain, audio)
        let legacy = TelegramAttachment(id: "id", kind: .file, name: "file", byteCount: nil,
            mimeType: nil, hasPreview: false, canDownload: true)
        XCTAssertNil(legacy.playback)
    }

    func testPaidNestedPlayableFileNeverBecomesPlaybackCandidate() {
        let audio = file(resource: LocalFileMediaResource(fileId: 703),
            attributes: [.Audio(isVoice: true, duration: 1, title: nil, performer: nil, waveform: nil)])
        let paid = TelegramMediaPaidContent(amount: 100, extendedMedia: [.full(media: audio)])
        let descriptor = telegramAttachments(message([paid]))[0].attachment
        XCTAssertNil(descriptor.playback)
        XCTAssertFalse(descriptor.canDownload)
        XCTAssertEqual(descriptor.kind, .unsupported)
    }

}
