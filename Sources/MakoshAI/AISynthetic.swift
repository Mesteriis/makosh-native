import Foundation
import MakoshCore

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

    /// Bag-of-characters vectors: deterministic and offline, close for similar text.
    public func embeddings(connection: AIConnection, token: String?, model: String, inputs: [String]) async throws -> [[Float]] {
        inputs.map { input in
            var vector = [Float](repeating: 0.001, count: 16)
            for scalar in input.lowercased().unicodeScalars { vector[Int(scalar.value % 16)] += 1 }
            return vector
        }
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

/// Synthetic archive conversation for the AI QA preview, enabled for the AI.
/// Fixed observation IDs make reseeding a no-op.
public enum AISyntheticSeed {
    public static let scope = AIAccessScope.conversation(service: "telegram", accountID: "qa-ai", conversationID: "qa-ai-chat")

    @discardableResult
    public static func seed(_ store: MessageArchiveStore) throws -> AIAccessScope {
        let lines: [(String, Bool)] = [
            ("Привет! Отчёт по проекту «Север» пришлю в пятницу.", false),
            ("Хорошо, жду. Не забудь бюджет на второй квартал.", true),
            ("Бюджет на второй квартал — 1,2 млн, согласован с финансами.", false),
            ("Отлично, тогда встреча с командой во вторник в 11:00.", true),
        ]
        let observations = lines.enumerated().map { index, line in
            MessageArchiveObservation(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                identity: MessageArchiveIdentity(
                    service: "telegram", accountID: "qa-ai", conversationID: "qa-ai-chat", messageID: "0:\(index + 1)"),
                observedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)), source: .synthetic,
                event: .message(
                    MessageArchiveContent(
                        date: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 60), text: line.0,
                        author: line.1 ? "Вы" : "Синтетический коллега",
                        authorID: line.1 ? "qa-self" : "qa-peer", isOutgoing: line.1)))
        }
        _ = try store.append(observations)
        try store.setAIAccess(scope, enabled: true)
        return scope
    }
}
