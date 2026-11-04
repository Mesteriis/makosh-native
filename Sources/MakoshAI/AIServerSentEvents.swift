import Foundation

public enum AIStreamEvent: Sendable, Equatable { case delta(String), done }

/// Parses chat-completion server-sent events one line at a time. Comments,
/// role-only deltas and blank lines yield nothing.
struct AIServerSentEvents {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]
    }

    mutating func feed(_ line: String) throws -> AIStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { throw AIFailure.malformedResponse }
        guard let content = chunk.choices.first?.delta?.content, !content.isEmpty else { return nil }
        return .delta(content)
    }
}
