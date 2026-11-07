import Foundation

/// One line of quick entry: `Название @список #тег /персона !1 ^срок *повтор
/// >>цепочка ~код`. A token that does not resolve stays in the title and is
/// reported unresolved, so the preview can say why.
public struct TaskQuickEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case text, list, tag, persona, priority, due, recurrence, flow, dependency, url }
    public struct Token: Equatable, Sendable {
        public let kind: Kind
        public let text: String
        public let resolved: Bool
        public init(kind: Kind, text: String, resolved: Bool = true) {
            self.kind = kind
            self.text = text
            self.resolved = resolved
        }
    }

    public var title = ""
    public var list: String?
    public var tags: [String] = []
    public var personas: [String] = []
    public var priority: Int?
    public var due: Date?
    public var recurrence: String?
    public var flowID: String?
    /// Codes or keys that resolved, in order; `dependencies` are their ids.
    public var dependencyRefs: [String] = []
    public var dependencies: [UUID] = []
    public var url: URL?
    public var tokens: [Token] = []

    public static func parse(
        _ input: String, today: Date, calendar: Calendar, resolveDependency: (String) -> UUID?, extractURLs: Bool = true
    ) -> TaskQuickEntry {
        var entry = TaskQuickEntry()
        var titleParts: [String] = []
        for word in input.split(whereSeparator: \.isWhitespace).map(String.init) {
            let body = String(word.dropFirst())
            if word.hasPrefix(">>"), word.count > 2 {
                entry.flowID = String(word.dropFirst(2))
                entry.tokens.append(Token(kind: .flow, text: word))
            } else if word.hasPrefix("@"), !body.isEmpty {
                entry.list = body
                entry.tokens.append(Token(kind: .list, text: word))
            } else if word.hasPrefix("#"), !body.isEmpty {
                entry.tags.append(body)
                entry.tokens.append(Token(kind: .tag, text: word))
            } else if word.hasPrefix("/"), !body.isEmpty {
                entry.personas.append(body)
                entry.tokens.append(Token(kind: .persona, text: word))
            } else if word.hasPrefix("!"), body.count == 1, let value = Int(body), (1...4).contains(value) {
                entry.priority = value
                entry.tokens.append(Token(kind: .priority, text: word))
            } else if word.hasPrefix("^") {
                if let date = TaskDateParser.parse(body, today: today, calendar: calendar) {
                    entry.due = date
                    entry.tokens.append(Token(kind: .due, text: word))
                } else {
                    titleParts.append(word)
                    entry.tokens.append(Token(kind: .due, text: word, resolved: false))
                }
            } else if word.hasPrefix("*"), !body.isEmpty {
                if let recurrence = TaskRecurrence.normalize(body) {
                    entry.recurrence = recurrence
                    entry.tokens.append(Token(kind: .recurrence, text: word))
                } else {
                    titleParts.append(word)
                    entry.tokens.append(Token(kind: .recurrence, text: word, resolved: false))
                }
            } else if word.hasPrefix("~"), !body.isEmpty {
                if let id = resolveDependency(body) {
                    entry.dependencyRefs.append(body)
                    entry.dependencies.append(id)
                    entry.tokens.append(Token(kind: .dependency, text: word))
                } else {
                    titleParts.append(word)
                    entry.tokens.append(Token(kind: .dependency, text: word, resolved: false))
                }
            } else if extractURLs, entry.url == nil, let url = Self.url(word) {
                entry.url = url
                entry.tokens.append(Token(kind: .url, text: word))
            } else {
                titleParts.append(word)
                entry.tokens.append(Token(kind: .text, text: word))
            }
        }
        entry.title = titleParts.joined(separator: " ")
        return entry
    }

    static func url(_ word: String) -> URL? {
        guard let url = URL(string: word), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    /// The token kind a single word would commit as; nil for plain text.
    static func kind(of word: String, extractURLs: Bool) -> Kind? {
        if word.hasPrefix(">>"), word.count > 2 { return .flow }
        if word.hasPrefix("@"), word.count > 1 { return .list }
        if word.hasPrefix("#"), word.count > 1 { return .tag }
        if word.hasPrefix("/"), word.count > 1 { return .persona }
        if word.hasPrefix("!"), word.count == 2, let value = Int(word.dropFirst()), (1...4).contains(value) { return .priority }
        if word.hasPrefix("^"), word.count > 1 { return .due }
        if word.hasPrefix("~"), word.count > 1 { return .dependency }
        if word.hasPrefix("*"), word.count > 1 { return .recurrence }
        if extractURLs, url(word) != nil { return .url }
        return nil
    }
}
