import Foundation
import Postbox
import TelegramCore

/// Immutable identity for a bounded JPEG, used in distinct video-frame,
/// video-cover and WebP-preview roles. Bytes stay in MediaBox, not Postbox.
struct TelegramUploadVideoThumbnailResource: Sendable {
    let id: Int64
    let width: Int32
    let height: Int32
    let size: Int64

    var isValid: Bool { width > 0 && height > 0 && width <= 320 && height <= 320 && size > 0 && size <= 1_048_576 }
    var resource: LocalFileMediaResource { LocalFileMediaResource(fileId: id, size: size, isSecretRelated: false) }
    var representation: TelegramMediaImageRepresentation {
        TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: width, height: height),
            resource: resource, progressiveSizes: [], immediateThumbnailData: nil)
    }

    func matches(_ preview: TelegramMediaImageRepresentation) -> Bool {
        guard isValid, let resource = preview.resource as? LocalFileMediaResource else { return false }
        // Native == omits these flags and immediate/progressive thumbnail data.
        return resource.fileId == id && resource.size == size && !resource.isSecretRelated &&
            preview.dimensions == PixelDimensions(width: width, height: height) &&
            preview.progressiveSizes.isEmpty && preview.immediateThumbnailData == nil &&
            !preview.hasVideo && !preview.isPersonal && preview.typeHint == .generic
    }
}
