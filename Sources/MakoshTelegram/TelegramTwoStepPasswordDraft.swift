import Foundation

public struct TelegramTwoStepPasswordDraft: CustomStringConvertible, CustomDebugStringConvertible {
    public enum Stage: Hashable { case password, confirmation, hint, email, review }
    public let kind: TelegramTwoStepKind
    public private(set) var stage: Stage = .password
    public var password = "", confirmation = "", hint = "", email = ""
    public init(kind: TelegramTwoStepKind) { self.kind = kind }
    private var value: TelegramTwoStepInput { .init(password: password, confirmation: confirmation, hint: hint, email: kind == .setPassword ? email : "") }
    public var input: TelegramTwoStepInput? { stage == .review && value.isValid(for: kind) ? value : nil }
    @discardableResult public mutating func advance(skipEmail: Bool = false) -> Bool {
        guard kind == .setPassword || kind == .changePassword else { return false }
        switch stage {
        case .password:
            guard !password.isEmpty, password.utf8.count <= 1024 else { return false }; stage = .confirmation
        case .confirmation:
            guard telegramTwoStepPasswordBytesEqual(password, confirmation) else { return false }; stage = .hint
        case .hint:
            guard TelegramTwoStepInput(password: password,confirmation: confirmation,hint: hint).isValid(for: kind) else { return false }
            stage = kind == .setPassword ? .email : .review
        case .email:
            guard (skipEmail && email.isEmpty || !email.isEmpty), value.isValid(for: .setPassword) else { return false }; stage = .review
        case .review: return false
        }
        return true
    }
    public mutating func back() {
        switch stage {
        case .password: break
        case .confirmation: stage = .password
        case .hint: stage = .confirmation
        case .email: stage = .hint
        case .review: stage = kind == .setPassword ? .email : .hint
        }
    }
    public mutating func clear() { password = ""; confirmation = ""; hint = ""; email = ""; stage = .password }
    public var description: String { "TelegramTwoStepPasswordDraft(<redacted>)" }
    public var debugDescription: String { description }
}
