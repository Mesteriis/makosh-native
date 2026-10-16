import Foundation
import Network

/// Owned loopback-only listener; construction is pure and all socket callbacks enter this service actor.
actor TeamsLoopbackAuthorization {
    private let queue = DispatchQueue(label: "org.makosh.teams.oauth.loopback")
    private let lifetime: Duration
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, any Error>?
    private var waiting: CheckedContinuation<Data, any Error>?
    private var callbackURL: URL?
    private var expectedState: String?
    private var accepted: Data?
    private var returned = false
    private var cancelled = false
    private var failure: TeamsFailure?
    private var deadline: Task<Void, Never>?
    private struct Connection {
        let socket: NWConnection
        var buffer = Data()
        let timeout: Task<Void, Never>
    }
    private var connections: [UUID: Connection] = [:]

    init(lifetime: Duration = .seconds(300)) { self.lifetime = lifetime }

    func start() async throws -> URL {
        guard listener == nil, !cancelled, callbackURL == nil else { throw TeamsFailure.invalidAuthorization }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let owned: NWListener
        do { owned = try NWListener(using: parameters) } catch { throw TeamsFailure.transport }
        listener = owned
        owned.stateUpdateHandler = { [weak self, weak owned] state in
            let port = owned?.port?.rawValue
            Task { await self?.stateChanged(state, port: port) }
        }
        owned.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        deadline = Task { [weak self, lifetime] in
            do { try await Task.sleep(for: lifetime) } catch { return }
            await self?.expire()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                owned.start(queue: queue)
            }
        } onCancel: { Task { await self.cancel() } }
    }

    func expect(state: String) throws {
        guard !state.isEmpty, state.utf8.count <= 256, !cancelled, accepted == nil, !returned else { throw TeamsFailure.invalidAuthorization }
        expectedState = state
    }

    func callback() async throws -> Data {
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
        if let accepted { self.accepted = nil; returned = true; return accepted }
        guard callbackURL != nil, expectedState != nil, waiting == nil, !returned else { throw TeamsFailure.invalidAuthorization }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting = $0 }
        } onCancel: { Task { await self.cancel() } }
    }

    func cancel() {
        cancelled = true
        stopListening()
        for connection in connections.values { connection.timeout.cancel(); connection.socket.cancel() }
        connections.removeAll()
        ready?.resume(throwing: CancellationError()); ready = nil
        waiting?.resume(throwing: CancellationError()); waiting = nil
        accepted = nil
    }

    private func stateChanged(_ state: NWListener.State, port: UInt16?) {
        guard !cancelled, failure == nil, !returned else { return }
        switch state {
        case .ready:
            guard let port, let url = URL(string: "http://127.0.0.1:\(port)/callback") else { expire(); return }
            callbackURL = url; ready?.resume(returning: url); ready = nil
        case .failed:
            failure = .transport; stopListening()
            ready?.resume(throwing: TeamsFailure.transport); ready = nil
            waiting?.resume(throwing: TeamsFailure.transport); waiting = nil
        default: break
        }
    }

    private func accept(_ socket: NWConnection) {
        guard !cancelled, failure == nil, accepted == nil, !returned, connections.count < 4 else { socket.cancel(); return }
        let id = UUID()
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.close(id)
        }
        connections[id] = Connection(socket: socket, timeout: timeout)
        socket.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let connection = connections[id] else { return }
        guard connection.buffer.count < 8192 else { respond(id, success: false); return }
        connection.socket.receive(minimumIncompleteLength: 1, maximumLength: 8192 - connection.buffer.count) { [weak self] data, _, complete, error in
            Task { await self?.received(id, data: data, complete: complete, failed: error != nil) }
        }
    }

    private func received(_ id: UUID, data: Data?, complete: Bool, failed: Bool) {
        guard var connection = connections[id], !cancelled, failure == nil, !returned else { close(id); return }
        if let data { connection.buffer.append(data) }
        connections[id] = connection
        if let end = connection.buffer.range(of: Data("\r\n\r\n".utf8)) {
            guard end.upperBound == connection.buffer.endIndex, let callbackURL, let expectedState,
                  let query = try? TeamsLoopbackCallback.parse(connection.buffer, callbackURL: callbackURL),
                  query["state"] == expectedState, query["code"] != nil || query["error"] != nil else { respond(id, success: false); return }
            let callback = connection.buffer
            stopListening()
            for otherID in connections.keys where otherID != id { close(otherID) }
            if let waiting { self.waiting = nil; returned = true; waiting.resume(returning: callback) }
            else { accepted = callback }
            respond(id, success: true)
        } else if complete || failed || connection.buffer.count >= 8192 { respond(id, success: false) }
        else { receive(id) }
    }

    private func respond(_ id: UUID, success: Bool) {
        guard let connection = connections[id] else { return }
        let body = success ? "Request received. Return to Makosh to finish signing in." : "Invalid callback. Return to Makosh."
        let response = "HTTP/1.1 \(success ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.socket.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { await self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.timeout.cancel(); connection.socket.cancel()
    }
    private func stopListening() {
        deadline?.cancel(); deadline = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
    }
    private func expire() {
        guard !cancelled, !returned, accepted == nil else { return }
        failure = .authorizationExpired; stopListening()
        for id in Array(connections.keys) { close(id) }
        ready?.resume(throwing: TeamsFailure.authorizationExpired); ready = nil
        waiting?.resume(throwing: TeamsFailure.authorizationExpired); waiting = nil
    }
}
