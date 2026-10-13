#if DEBUG
import Foundation

@MainActor final class TelegramSyntheticAvatarEditingProvider: TelegramAvatarEditingProvider {
    let accountID: Int64 = 101
    private var values: [TelegramAvatarTarget: TelegramAvatarSnapshot] = [:]
    func load(target: TelegramAvatarTarget, receive: @escaping @MainActor (Result<TelegramAvatarSnapshot, TelegramAvatarError>) -> Void) -> any TelegramAvatarEditingRequest {
        let request = SyntheticAvatarEditingRequest()
        guard target.isValid, target.accountID == accountID else { receive(.failure(.unavailable)); return request }
        let value = values[target] ?? .init(target: target, title: target.peerID == accountID ? "Synthetic own profile" : "Synthetic group/channel", photoID: 5, canEdit: true)
        values[target] = value; receive(.success(value)); return request
    }
    func apply(basis: TelegramAvatarSnapshot, photo: TelegramAvatarPhoto?, receive: @escaping @MainActor (TelegramAvatarEditingEvent) -> Bool) -> any TelegramAvatarEditingRequest {
        let request = SyntheticAvatarEditingRequest()
        guard basis == values[basis.target], basis.canEdit, photo?.isValid ?? true else { _ = receive(.failed(.changed)); return request }
        guard receive(.progress(0.5)) else { return request }
        request.task = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, !Task.isCancelled, self.values[basis.target] == basis else { return }
            guard receive(.committing) else { return }
            let value = TelegramAvatarSnapshot(target: basis.target, title: basis.title, photoID: photo == nil ? nil : (basis.photoID ?? 5) + 1, canEdit: true)
            self.values[basis.target] = value; _ = receive(.saved(value))
        }
        return request
    }
}
@MainActor private final class SyntheticAvatarEditingRequest: TelegramAvatarEditingRequest {
    var task: Task<Void, Never>?
    func cancel() { task?.cancel(); task = nil }
    isolated deinit { task?.cancel() }
}
#endif
