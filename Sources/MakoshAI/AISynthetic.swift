import Foundation

/// Deterministic offline provider for the synthetic preview. It never opens
/// a network connection, whatever URL the connection names.
public struct AISyntheticService: AIServing {
    public init() {}

    public func models(connection: AIConnection, token: String?) async throws -> [String] {
        ["synthetic-chat", "synthetic-embed", "synthetic-image", "synthetic-speech", "synthetic-transcribe"]
    }

    public func chat(
        connection: AIConnection, token: String?, model: String, turns: [AIChatTurn]
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        let question = turns.last { $0.author == .user }?.text ?? ""
        let parts = ["Синтетический ", "ответ ", "на «", String(question.prefix(40)), "»."]
        return AsyncThrowingStream { continuation in
            let task = Task {
                for part in parts {
                    try? await Task.sleep(for: .milliseconds(150))
                    if Task.isCancelled { break }
                    continuation.yield(.delta(part))
                }
                if !Task.isCancelled { continuation.yield(.done) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func image(connection: AIConnection, token: String?, model: String, prompt: String) async throws -> Data {
        // 1×1 violet PNG.
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNoaPj/HwAFAAJ/oq2GWgAAAABJRU5ErkJggg==")!
    }

    public func transcribe(connection: AIConnection, token: String?, model: String, audio: URL) async throws -> String {
        "Синтетическая расшифровка"
    }

    public func speech(connection: AIConnection, token: String?, model: String, text: String) async throws -> Data {
        throw AIFailure.server(status: 501)
    }
}

/// In-memory token store for the synthetic preview; nothing reaches the Keychain.
public actor AIMemoryTokenVault: AITokenStoring {
    private var tokens: [UUID: String] = [:]
    public init() {}
    public func load(connectionID: UUID) -> String? { tokens[connectionID] }
    public func save(_ token: String, connectionID: UUID) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        tokens[connectionID] = trimmed.isEmpty ? nil : trimmed
    }
    public func remove(connectionID: UUID) { tokens[connectionID] = nil }
}
