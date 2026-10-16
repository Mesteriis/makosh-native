import Foundation

/// MMail workflows, persisted in Makosh's encrypted state rather than UserDefaults.
public struct MailReplyTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID; public var name: String; public var body: String
    public init(id: UUID = UUID(), name: String, body: String) { self.id = id; self.name = name; self.body = body }
}
public struct MailIncomingRule: Codable, Equatable, Identifiable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable { case from, subject }
    public enum Action: String, Codable, CaseIterable, Sendable { case archive, trash, label }
    public var id: UUID; public var accountID: String; public var field: Field; public var value: String
    public var action: Action; public var label: String?; public var enabled: Bool
    public init(id: UUID = UUID(), accountID: String, field: Field, value: String, action: Action, label: String? = nil, enabled: Bool = true) {
        self.id = id; self.accountID = accountID; self.field = field; self.value = value; self.action = action; self.label = label; self.enabled = enabled
    }
    public func matches(_ letter: MailLetter) -> Bool {
        guard enabled, accountID == letter.key.accountID, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let candidates = field == .from ? [letter.sender, letter.senderName] : [letter.subject]
        return candidates.contains { $0.range(of: value, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil }
    }
}
public struct MailRuleOperation: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case pending, admitted, completed, unknown, cancelled, preparationFailed }
    public var id: UUID = UUID(); public var key: MailMessageKey; public var destination: MailFolderKind; public var state: State = .pending; public var failure: String?
}
public struct MailAutomationState: Codable, Equatable, Sendable {
    public var signatures: [String: String] = [:]
    public var templates: [MailReplyTemplate] = []
    public var rules: [MailIncomingRule] = []
    public var labelsByLetter: [String: [String]] = [:]
    public var ruleOperations: [MailRuleOperation] = []
    public var scheduled: [MailScheduledSend]?
    private var checkpoints: [String: UInt32] = [:]
    public init() {}
    mutating func observe(_ letters: [MailLetter], folder: MailFolder, validity: UInt32, synchronizedThroughUID: UInt32? = nil) {
        guard folder.kind == .inbox else { return }
        let cursor = folder.id + "|" + String(validity)
        let maximum = max(letters.map(\.key.uid).max() ?? 0, synchronizedThroughUID ?? 0)
        let previous = checkpoints[cursor]; checkpoints[cursor] = max(previous ?? 0, maximum)
        guard let previous else { return }
        for letter in letters where letter.key.uid > previous && letter.removedFromSource != true {
            var destination: MailFolderKind?
            var labels = Set(labelsByLetter[letter.id] ?? [])
            for rule in rules where rule.matches(letter) {
                switch rule.action {
                case .trash: destination = .trash
                case .archive: if destination != .trash { destination = .archive }
                case .label: if let label = rule.label { labels.insert(label) }
                }
            }
            if !labels.isEmpty { labelsByLetter[letter.id] = labels.sorted() }
            if let destination, !ruleOperations.contains(where: { $0.key == letter.key }) {
                ruleOperations.append(.init(key: letter.key, destination: destination))
            }
        }
    }
}
public struct MailScheduledSend: Codable, Equatable, Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case pending, admitted, completed, unknown, cancelled }
    public let id: UUID; public let draft: MailDraft; public let sendAt: Date; public var state: State
    public init(id: UUID = UUID(), draft: MailDraft, sendAt: Date, state: State = .pending) { self.id = id; self.draft = draft; self.sendAt = sendAt; self.state = state }
}
public enum MailComposition {
    public static func insertingSignature(_ signature: String, into draft: MailDraft) -> MailDraft {
        guard !signature.isEmpty, draft.insertedSignature == nil else { return draft }
        var value = draft; value.body += "\n\n" + signature; value.insertedSignature = signature
        // Formatting is authored by the compose editor; never splice unescaped text into HTML.
        value.bodyHTML = nil; value.bodyRTF = nil; return value
    }
    public static func applying(_ template: MailReplyTemplate, to draft: MailDraft) -> MailDraft {
        var value = draft; value.body = template.body
        if let signature = draft.insertedSignature { value.body += "\n\n" + signature }
        value.bodyHTML = nil; value.bodyRTF = nil; return value
    }
}
