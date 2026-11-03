import Foundation
import TelegramCore
import SwiftSignalKit

@MainActor protocol TelegramCallEngine: AnyObject {
    var accountID: Int64 { get }
    func peer(_ id: Int64) -> Signal<TelegramCallPeer, TelegramCallError>
    func incoming() -> Signal<[TelegramIncomingCall], TelegramCallError>
    func request(peer: TelegramCallPeer, video: Bool, callID: UUID) -> Signal<UUID, TelegramCallError>
    func observe(callID: UUID) -> Signal<CallSession, TelegramCallError>
    func receiveSignaling(callID: UUID, receive: @escaping @MainActor (Result<Data, TelegramCallError>) -> Void) -> any TelegramCallRequest
    func accept(callID: UUID)
    func drop(callID: UUID, reason: DropCallReason)
    func send(callID: UUID, data: Data)
    func updateVideo(callID: UUID, enabled: Bool)
}
@MainActor protocol TelegramCallMediaFactory: AnyObject {
    func make(configuration: TelegramCallMediaConfiguration, receive: @escaping @MainActor (TelegramCallMediaEvent) -> Bool) -> TelegramCallMediaSession
}
@MainActor final class TelegramNativeCallMediaFactory: TelegramCallMediaFactory {
    func make(configuration: TelegramCallMediaConfiguration, receive: @escaping @MainActor (TelegramCallMediaEvent) -> Bool) -> TelegramCallMediaSession {
        .init(makeCore: { TelegramCallCBridge(configuration: configuration, inbox: $0) },
              makeCamera: { TelegramNativeCallCameraSource() }, video: configuration.video, receive: receive)
    }
}
@MainActor final class TelegramCallSignalRequest: TelegramCallRequest {
    let disposable = DisposableSet()
    private(set) var stopped = false
    func once<T>(_ signal: Signal<T, TelegramCallError>, receive: @escaping @MainActor (Result<T, TelegramCallError>) -> Void) {
        var delivered = false
        disposable.add((signal |> take(1) |> deliverOnMainQueue).start(next: { [weak self] value in
            MainActor.assumeIsolated { guard self?.stopped == false else { return }; delivered = true; receive(.success(value)) }
        }, error: { [weak self] error in
            MainActor.assumeIsolated { guard self?.stopped == false else { return }; delivered = true; receive(.failure(error)) }
        }, completed: { [weak self] in
            MainActor.assumeIsolated { if self?.stopped == false && !delivered { receive(.failure(.unavailable)) } }
        }))
    }
    func cancel() { stopped = true; disposable.dispose() }
    isolated deinit { disposable.dispose() }
}
