# SPDX-License-Identifier: MIT
"""Own typed photo/multipart bridge inside independently pinned TelegramCore."""
def avatar_helper_source():
    return '''// Own Makosh MIT adapter; linked TelegramCore remains GPL-3.0-or-later.
import Foundation
import Postbox
import TelegramApi
import SwiftSignalKit

public enum MakoshAvatarFileUploadStatus { case progress(Float), complete(Api.InputFile) }
public enum MakoshAvatarFileUploadError: Error { case failed }
public func makoshAvatarUploadFile(account: Account, jpeg: Data) -> Signal<MakoshAvatarFileUploadStatus, MakoshAvatarFileUploadError> {
    guard !jpeg.isEmpty, jpeg.count <= 2 * 1024 * 1024 else { return .fail(.failed) }
    return multipartUpload(network: account.network, postbox: account.postbox, source: .data(jpeg), encrypt: false,
        tag: TelegramMediaResourceFetchTag(statsCategory: .image, userContentType: .image), hintFileSize: Int64(jpeg.count),
        hintFileIsLarge: false, forceNoBigParts: true)
        |> mapError { _ in MakoshAvatarFileUploadError.failed }
        |> map { value in
            switch value {
            case let .progress(value): return .progress(value)
            case let .inputFile(file): return .complete(file)
            case .inputSecretFile: return .progress(Float.nan)
            }
        }
}
public struct MakoshAvatarPeerPhoto {
    public let peer: Peer
    public let image: TelegramMediaImage?
}
public func makoshAvatarImage(_ photo: Api.Photo) -> TelegramMediaImage? { telegramMediaImageFromApiPhoto(photo) }
public func makoshAvatarUpdatedChat(_ updates: Api.Updates, peerId: PeerId) -> Peer? {
    let chats: [Api.Chat]
    switch updates {
    case let .updates(_, _, values, _, _): chats = values
    case let .updatesCombined(_, _, values, _, _, _): chats = values
    default: return nil
    }
    guard chats.count <= 1000 else { return nil }
    let peers = chats.compactMap(parseTelegramGroupOrChannel)
    guard Set(peers.map { $0.id }).count == peers.count,
          let peer = peers.first(where: { $0.id == peerId }) else { return nil }
    if let channel = peer as? TelegramChannel {
        guard case let .personal(hash) = channel.accessHash, hash != 0 else { return nil }
    }
    return peer
}
private func validMakoshAvatarPhoto(_ photo: Api.Photo?) -> Bool {
    guard let photo else { return true }
    switch photo {
    case .photoEmpty: return true
    case let .photo(_, id, _, _, _, sizes, _, dcId):
        guard id > 0, dcId > 0, !sizes.isEmpty, sizes.count <= 64,
              let image = telegramMediaImageFromApiPhoto(photo), !image.representations.isEmpty else { return false }
        return image.representations.allSatisfy { $0.dimensions.width > 0 && $0.dimensions.height > 0 && $0.dimensions.width <= 8192 && $0.dimensions.height <= 8192 }
    }
}
private func consistentMakoshAvatarPhoto(_ peer: Peer, _ image: TelegramMediaImage?) -> Bool {
    if peer.profileImageRepresentations.isEmpty { return image == nil }
    guard let image, image.imageId.id > 0 else { return false }
    return peer.profileImageRepresentations.allSatisfy { ($0.resource as? CloudPeerPhotoSizeMediaResource)?.photoId == image.imageId.id }
}
public func makoshAvatarUserPhotoResult(_ result: Api.users.UserFull, accountPeerId: PeerId, fallback: Bool) -> MakoshAvatarPeerPhoto? {
    switch result {
    case let .userFull(full, chats, users):
        guard accountPeerId.namespace == Namespaces.Peer.CloudUser, accountPeerId.id._internalGetInt64Value() > 0,
              chats.count <= 1000, users.count <= 1000, Set(users.map { $0.peerId }).count == users.count,
              let apiUser = users.first(where: { $0.peerId == accountPeerId }) else { return nil }
        let peer = TelegramUser(user: apiUser)
        guard !peer.isDeleted else { return nil }
        switch apiUser {
        case let .user(flags, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _):
            guard flags & (1 << 20) == 0 else { return nil }
        default: return nil
        }
        switch full {
        case let .userFull(_, _, id, _, _, _, profilePhoto, fallbackPhoto, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _):
            let photo = fallback ? fallbackPhoto : profilePhoto
            guard id == accountPeerId.id._internalGetInt64Value(), validMakoshAvatarPhoto(photo) else { return nil }
            let image = photo.flatMap(telegramMediaImageFromApiPhoto)
            guard fallback || consistentMakoshAvatarPhoto(peer, image) else { return nil }
            return MakoshAvatarPeerPhoto(peer: peer, image: image)
        }
    }
}
public func makoshAvatarChatPhotoResult(_ result: Api.messages.ChatFull, peerId: PeerId) -> MakoshAvatarPeerPhoto? {
    switch result {
    case let .chatFull(full, chats, users):
        guard [Namespaces.Peer.CloudGroup, Namespaces.Peer.CloudChannel].contains(peerId.namespace),
              peerId.id._internalGetInt64Value() > 0, chats.count <= 1000, users.count <= 1000 else { return nil }
        let peers = chats.compactMap(parseTelegramGroupOrChannel)
        guard Set(peers.map { $0.id }).count == peers.count,
              let peer = peers.first(where: { $0.id == peerId }) else { return nil }
        if let channel = peer as? TelegramChannel {
            guard case let .personal(hash) = channel.accessHash, hash != 0 else { return nil }
        }
        let photo: Api.Photo?
        switch full {
        case let .chatFull(_, id, _, _, chatPhoto, _, _, _, _, _, _, _, _, _, _, _, _, _):
            guard peerId.namespace == Namespaces.Peer.CloudGroup, id == peerId.id._internalGetInt64Value() else { return nil }; photo = chatPhoto
        case let .channelFull(_, _, id, _, _, _, _, _, _, _, _, _, chatPhoto, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _):
            guard peerId.namespace == Namespaces.Peer.CloudChannel, id == peerId.id._internalGetInt64Value() else { return nil }; photo = chatPhoto
        }
        guard validMakoshAvatarPhoto(photo) else { return nil }
        let image = photo.flatMap(telegramMediaImageFromApiPhoto)
        guard consistentMakoshAvatarPhoto(peer, image) else { return nil }
        return MakoshAvatarPeerPhoto(peer: peer, image: image)
    }
}
'''
