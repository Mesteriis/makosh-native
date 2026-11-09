import Foundation

/// The flowsint release Makosh installs on the server. The same values live in
/// `Dependencies/Flowsint.lock.json`; `scripts/test-flowsint-pin.py` keeps them equal.
public struct FlowsintPin: Codable, Equatable, Sendable {
    public var repository: String
    public var tag: String
    public var sha: String
    /// Base images of the upstream Dockerfiles, by tag: an accepted limitation of building on the server.
    public var baseImages: [String]

    public init(repository: String, tag: String, sha: String, baseImages: [String]) {
        self.repository = repository
        self.tag = tag
        self.sha = sha
        self.baseImages = baseImages
    }

    public static let current = FlowsintPin(
        repository: "https://github.com/reconurge/flowsint",
        tag: "v1.2.13",
        sha: "4c05849bc6ca5055ad187d056ef26e61b3bc2fea",
        baseImages: ["python:3.12-slim", "node:24-alpine", "nginx:1.29-alpine"])
}
