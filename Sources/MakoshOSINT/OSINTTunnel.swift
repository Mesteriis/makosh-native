import Foundation
import NIOCore

/// A loopback listener bound to `127.0.0.1:0` whose connections are forwarded through the SSH session.
public final class OSINTTunnel: Sendable {
    public let localPort: Int
    private let server: Channel

    init(server: Channel) {
        self.server = server
        localPort = server.localAddress?.port ?? 0
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(localPort)")! }

    public func close() async {
        try? await server.close().get()
    }
}
