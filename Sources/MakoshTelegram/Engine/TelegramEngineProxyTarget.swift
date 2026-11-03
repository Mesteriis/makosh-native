import TelegramCore
import SwiftSignalKit

@MainActor final class TelegramEngineProxyTarget: TelegramProxyTarget {
    private weak var network: Network?
    private let stopped: @MainActor () -> Void
    init(network: Network, stopped: @escaping @MainActor () -> Void) { self.network = network; self.stopped = stopped }
    var isAvailable: Bool { network != nil }
    func failClosed() { stopped() }
    func apply(_ configuration: TelegramProxyConfiguration, receive: @escaping @MainActor (Bool) -> Void) -> any TelegramProxyRequest {
        guard let network, network.makoshUsesExternalProxySettings else { receive(false); return Request(nil) }
        let disposable = (telegramApplyProxy(context: network.context, configuration: configuration,
            didChange: { [weak network] in network?.dropConnectionStatus() }) |> deliverOnMainQueue).start(next: receive)
        return Request(disposable)
    }
    private final class Request: TelegramProxyRequest {
        private var disposable: Disposable?
        init(_ disposable: Disposable?) { self.disposable = disposable }
        func cancel() { disposable?.dispose(); disposable = nil }
        isolated deinit { cancel() }
    }
}
