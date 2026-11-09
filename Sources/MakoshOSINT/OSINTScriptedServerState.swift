#if DEBUG
import Foundation
import NIOConcurrencyHelpers

/// What LXC 164 looks like to the installer, as a script for `OSINTSyntheticSSHServer`: Docker and
/// git presence, the checkout, `.env`, the compose override, built images and a running stack.
/// Shared by the installer tests and the persons QA seed. Never holds secrets beyond the test process.
public final class OSINTScriptedServerState: @unchecked Sendable {
    private let lock = NIOLock()
    public var hasDocker: Bool
    public var hasGit: Bool
    /// What a clone or checkout lands on; the pin's SHA unless a test wants a mismatch.
    public var cloneSHA: String
    public var checkoutSHA: String?
    public var hasEnv: Bool
    public var envWrites = 0
    public var lastEnv: String?
    public var overrideText: String?
    public var builtSHA: String?
    public var up = false
    public var commands: [String] = []
    /// Runs after `compose up`: the QA flips its synthetic flowsint to installed here.
    public var onUp: (@Sendable () -> Void)?

    public init(hasDocker: Bool = true, hasGit: Bool = true, cloneSHA: String = FlowsintPin.current.sha, hasEnv: Bool = false) {
        self.hasDocker = hasDocker
        self.hasGit = hasGit
        self.cloneSHA = cloneSHA
        self.hasEnv = hasEnv
    }

    public var script: OSINTSyntheticSSHServer.Script { { [self] request in self.respond(request) } }

    public func respond(_ request: OSINTSyntheticSSHServer.Request) -> OSINTExecResult {
        lock.withLock {
            commands.append(request.command)
            let command = request.command
            func ok(_ out: String = "") -> OSINTExecResult { OSINTExecResult(status: 0, stdout: out, stderr: "") }
            func fail(_ status: Int32, _ err: String = "") -> OSINTExecResult { OSINTExecResult(status: status, stdout: "", stderr: err) }
            if command.hasPrefix("docker version") {
                return hasDocker ? ok("29.9.3\nv5.7.0\n") : fail(127, "docker: not found\n")
            }
            if command == "git --version" { return hasGit ? ok("git version 2.47.2\n") : fail(127, "git: not found\n") }
            if command == "git -C /opt/flowsint rev-parse HEAD" {
                return checkoutSHA.map { ok($0 + "\n") } ?? fail(128, "fatal: not a git repository\n")
            }
            if command.hasPrefix("git clone ") || command.hasPrefix("git -C /opt/flowsint fetch ") {
                checkoutSHA = cloneSHA
                return ok(cloneSHA + "\n")
            }
            if command == "test -f /opt/flowsint/.env" { return hasEnv ? ok() : fail(1) }
            if command == "install -m 600 /dev/stdin /opt/flowsint/.env" {
                hasEnv = true
                envWrites += 1
                lastEnv = request.stdin
                return ok()
            }
            if command == "cat /opt/flowsint/docker-compose.makosh.yml" { return overrideText.map { ok($0) } ?? fail(1) }
            if command == "install -m 644 /dev/stdin /opt/flowsint/docker-compose.makosh.yml" {
                overrideText = request.stdin
                return ok()
            }
            if command.hasPrefix("docker image inspect --format '{{.Id}}' flowsint-") {
                let name = command.split(separator: " ").last.map(String.init) ?? ""
                return builtSHA != nil && name.hasSuffix(":" + (builtSHA ?? ""))
                    ? ok("sha256:" + String(name.prefix(12).hashValue.magnitude) + "\n") : fail(1)
            }
            if command.hasPrefix("cd /opt/flowsint && docker compose") {
                if command.hasSuffix(" build") {
                    builtSHA = checkoutSHA
                    return ok("#1 [api] FROM python:3.12-slim\n#2 [app] FROM node:24-alpine\nbuilt\n")
                }
                if command.contains(" pull ") { return ok("pulled\n") }
                if command.contains(" up -d") {
                    up = true
                    onUp?()
                    return ok("started\n")
                }
            }
            return fail(127, "unknown command\n")
        }
    }
}
#endif
