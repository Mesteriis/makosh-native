import Foundation
import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit

func telegramAvatarSnapshot(peer: Peer, image: TelegramMediaImage?, target: TelegramAvatarTarget) -> TelegramAvatarSnapshot? {
    guard target.isValid, peer.id.toInt64() == target.peerID else { return nil }
    let editable: Bool
    if let user = peer as? TelegramUser {
        guard target.peerID == target.accountID, !user.isDeleted, user.botInfo == nil else { return nil }; editable = true
    } else if let group = peer as? TelegramGroup {
        guard target.kind == .main, group.membership == .Member, group.migrationReference == nil, !group.flags.contains(.deactivated) else { return nil }
        switch group.role { case .creator, .admin: editable = true; case .member: editable = !group.hasBannedPermission(.banChangeInfo) }
    } else if let channel = peer as? TelegramChannel {
        guard target.kind == .main, case let .personal(hash) = channel.accessHash, hash != 0, channel.participationStatus == .member, !channel.flags.contains(.isMonoforum) else { return nil }
        editable = channel.hasPermission(.changeInfo)
    } else { return nil }
    let value = TelegramAvatarSnapshot(target: target, title: telegramPeerTitle(peer), photoID: image?.imageId.id, canEdit: editable)
    return value.isValid ? value : nil
}
func telegramAvatarUserRPC(target: TelegramAvatarTarget, file: Api.InputFile?) -> (FunctionDescription, Buffer, DeserializeFunctionResponse<Api.photos.Photo>)? {
    guard target.isValid, target.peerID == target.accountID else { return nil }
    if let file {
        return Api.functions.photos.uploadProfilePhoto(flags: 1 | (target.kind == .fallback ? 8 : 0), bot: nil,
            file: file, video: nil, videoStartTs: nil, videoEmojiMarkup: nil)
    }
    return Api.functions.photos.updateProfilePhoto(flags: target.kind == .fallback ? 1 : 0, bot: nil, id: .inputPhotoEmpty)
}
func telegramAdmitAvatarChange(basis: TelegramAvatarSnapshot, fresh: TelegramAvatarSnapshot, removing: Bool) -> Bool {
    basis.isValid && fresh == basis && fresh.canEdit && (!removing || fresh.photoID != nil)
}
private struct AvatarNativeBasis { let peer: Peer; let snapshot: TelegramAvatarSnapshot }
private func avatarBasis(account: Account, target: TelegramAvatarTarget) -> Signal<AvatarNativeBasis, TelegramAvatarError> {
    guard target.isValid, account.peerId.toInt64() == target.accountID else { return .fail(.unavailable) }
    let id = PeerId(target.peerID)
    if id == account.peerId {
        return account.network.request(Api.functions.users.getFullUser(id: .inputUserSelf), automaticFloodWait: false)
            |> mapError { _ in TelegramAvatarError.failed } |> mapToSignal { result in
                guard let value = makoshAvatarUserPhotoResult(result, accountPeerId: account.peerId, fallback: target.kind == .fallback),
                      let snapshot = telegramAvatarSnapshot(peer: value.peer, image: value.image, target: target) else { return .fail(.unavailable) }
                return .single(.init(peer: value.peer, snapshot: snapshot))
            }
    }
    let result: Signal<Api.messages.ChatFull, TelegramAvatarError>
    if id.namespace == Namespaces.Peer.CloudGroup {
        result = account.network.request(Api.functions.messages.getFullChat(chatId: id.id._internalGetInt64Value()), automaticFloodWait: false) |> mapError { _ in .failed }
    } else {
        result = account.postbox.transaction { transaction -> Signal<Api.messages.ChatFull, TelegramAvatarError> in
            guard let peer = transaction.getPeer(id) as? TelegramChannel, let hash = peer.accessHash else { return .fail(.unavailable) }
            return account.network.request(Api.functions.channels.getFullChannel(channel: .inputChannel(channelId: id.id._internalGetInt64Value(), accessHash: hash.value)), automaticFloodWait: false) |> mapError { _ in .failed }
        } |> castError(TelegramAvatarError.self) |> switchToLatest
    }
    return result |> mapToSignal { response in
        guard let value = makoshAvatarChatPhotoResult(response, peerId: id),
              let snapshot = telegramAvatarSnapshot(peer: value.peer, image: value.image, target: target) else { return .fail(.unavailable) }
        return .single(.init(peer: value.peer, snapshot: snapshot))
    }
}
private func avatarWrite(account: Account, basis: AvatarNativeBasis, file: Api.InputFile?) -> Signal<Int64?, TelegramAvatarError> {
    let target = basis.snapshot.target
    if let rpc = telegramAvatarUserRPC(target: target, file: file) {
        return account.network.request(rpc, automaticFloodWait: false) |> mapError { _ in TelegramAvatarError.uncertain } |> mapToSignal { response in
            switch response {
            case let .photo(photo, _):
                if file == nil {
                    guard case .photoEmpty = photo else { return .fail(.uncertain) }; return .single(nil)
                }
                guard let image = makoshAvatarImage(photo), image.imageId.id > 0, !image.representations.isEmpty else { return .fail(.uncertain) }
                return .single(image.imageId.id)
            }
        }
    }
    let photo: Api.InputChatPhoto = file.map { .inputChatUploadedPhoto(flags: 1, file: $0, video: nil, videoStartTs: nil, videoEmojiMarkup: nil) } ?? .inputChatPhotoEmpty
    let result: Signal<Api.Updates, TelegramAvatarError>
    if let channel = basis.peer as? TelegramChannel, let hash = channel.accessHash {
        result = account.network.request(Api.functions.channels.editPhoto(channel: .inputChannel(channelId: channel.id.id._internalGetInt64Value(), accessHash: hash.value), photo: photo), automaticFloodWait: false) |> mapError { _ in .uncertain }
    } else if let group = basis.peer as? TelegramGroup {
        result = account.network.request(Api.functions.messages.editChatPhoto(chatId: group.id.id._internalGetInt64Value(), photo: photo), automaticFloodWait: false) |> mapError { _ in .uncertain }
    } else { return .fail(.unavailable) }
    return result |> mapToSignal { updates in
        account.stateManager.addUpdates(updates)
        guard let peer = makoshAvatarUpdatedChat(updates, peerId: basis.peer.id) else { return .fail(.uncertain) }
        let ids = Set(peer.profileImageRepresentations.compactMap { ($0.resource as? CloudPeerPhotoSizeMediaResource)?.photoId })
        if file == nil {
            guard peer.profileImageRepresentations.isEmpty else { return .fail(.uncertain) }; return .single(nil)
        }
        guard ids.count == 1, let id = ids.first, id > 0 else { return .fail(.uncertain) }; return .single(id)
    }
}
@MainActor final class TelegramEngineAvatarEditingProvider: TelegramAvatarEditingProvider {
    let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }
    func load(target: TelegramAvatarTarget, receive: @escaping @MainActor (Result<TelegramAvatarSnapshot, TelegramAvatarError>) -> Void) -> any TelegramAvatarEditingRequest {
        let request = AvatarEditingRequest()
        request.start(avatarBasis(account: account, target: target)) { result in receive(result.map(\.snapshot)) }
        return request
    }
    func apply(basis: TelegramAvatarSnapshot, photo: TelegramAvatarPhoto?, receive: @escaping @MainActor (TelegramAvatarEditingEvent) -> Bool) -> any TelegramAvatarEditingRequest {
        let request = AvatarEditingRequest(), account = account
        guard basis.isValid, basis.target.accountID == accountID, photo?.isValid ?? true else { _ = receive(.failed(.unavailable)); return request }
        let commit: @MainActor (Api.InputFile?) -> Void = { [weak request] file in
            guard let request, !request.stopped else { return }
            request.start(avatarBasis(account: account, target: basis.target)) { [weak request] response in
                guard let request, !request.stopped else { return }
                guard case let .success(fresh) = response else { _ = receive(.failed(.failed)); return }
                guard telegramAdmitAvatarChange(basis: basis, fresh: fresh.snapshot, removing: photo == nil) else { _ = receive(.failed(.changed)); return }
                guard receive(.committing), !request.stopped else { request.cancel(); return }
                request.start(avatarWrite(account: account, basis: fresh, file: file)) { [weak request] result in
                    guard let request, !request.stopped else { return }
                    guard case let .success(photoID) = result else { _ = receive(.failed(.uncertain)); return }
                    request.start(avatarBasis(account: account, target: basis.target)) { [weak request] confirmation in
                        guard let request, !request.stopped else { return }
                        guard case let .success(value) = confirmation, value.snapshot.photoID == photoID else { _ = receive(.failed(.uncertain)); return }
                        account.viewTracker.forceUpdateCachedPeerData(peerId: PeerId(basis.target.peerID))
                        _ = receive(.saved(value.snapshot))
                    }
                }
            }
        }
        if let photo {
            var completed = false
            request.disposable.add((makoshAvatarUploadFile(account: account, jpeg: photo.bytes) |> deliverOnMainQueue).start(next: { [weak request] value in
                MainActor.assumeIsolated {
                    guard let request, !request.stopped else { return }
                    switch value {
                    case let .progress(progress): if !receive(.progress(progress)) { request.cancel() }
                    case let .complete(file): guard !completed else { return }; completed = true; commit(file)
                    }
                }
            }, error: { _ in MainActor.assumeIsolated { if !request.stopped { _ = receive(.failed(.failed)) } } }, completed: {
                MainActor.assumeIsolated { if !completed && !request.stopped { _ = receive(.failed(.failed)) } }
            }))
        } else { commit(nil) }
        return request
    }
}
@MainActor private final class AvatarEditingRequest: TelegramAvatarEditingRequest {
    let disposable = DisposableSet()
    var stopped = false
    func start<T>(_ signal: Signal<T, TelegramAvatarError>, receive: @escaping @MainActor (Result<T, TelegramAvatarError>) -> Void) {
        guard !stopped else { return }
        var delivered = false
        disposable.add((signal |> take(1) |> deliverOnMainQueue).start(next: { [weak self] value in
            MainActor.assumeIsolated { guard self?.stopped == false else { return }; delivered = true; receive(.success(value)) }
        }, error: { [weak self] error in MainActor.assumeIsolated { if self?.stopped == false { receive(.failure(error)) } } }, completed: { [weak self] in
            MainActor.assumeIsolated { if !delivered && self?.stopped == false { receive(.failure(.failed)) } }
        }))
    }
    func cancel() { stopped = true; disposable.dispose() }
    isolated deinit { disposable.dispose() }
}
