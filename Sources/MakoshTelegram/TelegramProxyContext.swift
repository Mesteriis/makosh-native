import TelegramCore
import MtProtoKit
import SwiftSignalKit

nonisolated func telegramApplyProxy(context: MTContext, configuration: TelegramProxyConfiguration,
    didChange: @escaping () -> Void = {}) -> Signal<Bool, NoError> {
    guard let native = try? configuration.native() else { return .single(false) }
    let requested: MTSocksProxySettings?
    if let server = native.activeServer {
        switch server.connection {
        case let .socks5(username, password):
            requested = .init(ip: server.host, port: UInt16(server.port), username: username, password: password, secret: nil)
        case let .mtp(secret):
            requested = .init(ip: server.host, port: UInt16(server.port), username: nil, password: nil, secret: secret)
        }
    } else { requested = nil }
    func equal(_ current: MTSocksProxySettings?) -> Bool {
        if let current, let requested { return current.isEqual(requested) }
        return current == nil && requested == nil
    }
    return Signal { subscriber in
        context.updateApiEnvironment { environment in
            guard let environment, !equal(environment.socksProxySettings) else { return nil }
            didChange(); return environment.withUpdatedSocksProxySettings(requested)
        }
        // Both blocks use MTContext's serial queue. Acknowledgement observes the
        // committed environment; it does not claim a successful proxy handshake.
        context.updateApiEnvironment { environment in
            subscriber.putNext(environment.map { equal($0.socksProxySettings) } ?? false)
            subscriber.putCompletion(); return nil
        }
        return EmptyDisposable
    }
}
