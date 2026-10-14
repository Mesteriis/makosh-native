import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

@MainActor private final class NativeCacheRequest: TelegramCacheRequest {
    let disposables = DisposableSet()
    private var children: [any TelegramCacheRequest] = []
    private(set) var cancelled = false
    func add(_ request: any TelegramCacheRequest) { if cancelled { request.cancel() } else { children.append(request) } }
    func cancel() {
        guard !cancelled else { return }; cancelled = true
        disposables.dispose(); let old = children; children = []; for child in old { child.cancel() }
    }
    isolated deinit { disposables.dispose(); for child in children { child.cancel() } }
}

@MainActor final class TelegramEngineCacheProvider: TelegramCacheProvider {
    private let account: Account
    var accountID: Int64 { account.peerId.toInt64() }
    init(account: Account) { self.account = account }
    func scan(receive: @escaping @MainActor (TelegramCacheSnapshot?) -> Void) -> any TelegramCacheRequest {
        let request = NativeCacheRequest(); var received = false
        request.disposables.add((telegramReadCache(account: account) |> take(1) |> deliverOnMainQueue).start(next: { [weak request] value in
            guard let request, !request.cancelled else { return }; received = true; receive(value)
        }, completed: { [weak request] in
            guard let request, !request.cancelled, !received else { return }; received = true; receive(nil)
        }))
        return request
    }
    func clear(expected: TelegramCacheSnapshot, categories: Set<TelegramCacheKind>, permitted: @escaping @MainActor () -> Bool,
        receive: @escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest {
        clear(expected:expected,categories:categories,scope:.all,permitted:permitted,receive:receive)
    }
    func clear(expected: TelegramCacheSnapshot, categories: Set<TelegramCacheKind>, scope: TelegramCacheScope, permitted: @escaping @MainActor () -> Bool,
        receive: @escaping @MainActor (TelegramCacheEvent) -> Void) -> any TelegramCacheRequest {
        guard scope.isValid, !expected.selectedItems(categories:categories,scope:scope).isEmpty else { receive(.refused); return NativeCacheRequest() }
        let request = NativeCacheRequest()
        let scanRequest = scan { [weak self, weak request] fresh in
            guard let self, let request, !request.cancelled else { return }
            guard fresh == expected, expected.accountID == self.accountID else { receive(.changed(fresh)); return }
            var resolved = false
            request.disposables.add((telegramResolveCacheSelection(postbox: self.account.postbox, expected: expected, categories: categories, scope: scope)
                |> take(1) |> deliverOnMainQueue).start(next: { [weak self, weak request] media in
                    guard let self, let request, !request.cancelled else { return }; resolved = true
                    guard let media else { receive(.changed(nil)); return }
                    guard permitted() else { receive(.refused); return }
                    receive(.committing)
                    guard !request.cancelled, permitted() else { return }
                    let ids = Set(expected.selectedItems(categories:categories,scope:scope).flatMap(\.resources).map(MediaResourceId.init))
                    var acknowledged = false
                    request.disposables.add((telegramRemoveCloudCache(mediaBox: self.account.postbox.mediaBox, media: media, restrictingTo: ids)
                        |> take(1) |> deliverOnMainQueue).start(next: { [weak self, weak request] _ in
                            guard let self, let request, !request.cancelled else { return }; acknowledged = true
                            request.add(self.scan { [weak request] updated in
                                guard let request, !request.cancelled else { return }; receive(.finished(updated))
                            })
                        }, completed: { [weak request] in
                            guard let request, !request.cancelled, !acknowledged else { return }; receive(.uncertain)
                        }))
                }, completed: { [weak request] in
                    guard let request, !request.cancelled, !resolved else { return }; receive(.refused)
                }))
        }
        request.add(scanRequest); return request
    }
}
