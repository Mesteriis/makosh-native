import Foundation
import MakoshCore

/// Title starts with the query, then a word starts with it, then it appears
/// anywhere in the title or subtitle. Case and ё/е are ignored.
enum FileRanking {
    static func rank<T>(_ items: [T], query: String, limit: Int, title: (T) -> String, subtitle: (T) -> String) -> [T] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return Array(items.prefix(limit)) }
        let scored = items.enumerated().compactMap { index, item -> (Int, Int, T)? in
            let name = fold(title(item))
            if name.hasPrefix(needle) { return (0, index, item) }
            if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(needle) }) {
                return (1, index, item)
            }
            if name.contains(needle) || fold(subtitle(item)).contains(needle) { return (2, index, item) }
            return nil
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(limit).map(\.2)
    }
    static func fold(_ text: String) -> String { text.lowercased().replacingOccurrences(of: "ё", with: "е") }
}

/// Where a file can be forwarded: a chat's composer or a new letter.
public struct FileDestination: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case telegram(accountID: String, chatID: Int64)
        case whatsapp(accountID: UUID, chatID: String)
        case mail(address: String, contactID: UUID?)
    }
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public init(kind: Kind, title: String, subtitle: String) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }
    public var id: String {
        switch kind {
        case .telegram(let account, let chat): "telegram:\(account):\(chat)"
        case .whatsapp(let account, let chat): "whatsapp:\(account.uuidString.lowercased()):\(chat)"
        case .mail(let address, _): "mail:\(address.lowercased())"
        }
    }
}

public enum FileDestinationSearch {
    public static func rank(_ items: [FileDestination], query: String, limit: Int) -> [FileDestination] {
        FileRanking.rank(items, query: query, limit: limit, title: \.title, subtitle: \.subtitle)
    }
}

/// A file offered by "+" and "@": from the archive or from Paperless.
public struct FilePick: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case archive(FileCatalogueItem)
        case paperless(connectionID: UUID, document: PaperlessDocument)
    }
    public let kind: Kind
    public let title: String
    public let subtitle: String
    public var id: String {
        switch kind {
        case .archive(let item): "archive:\(item.id.uuidString.lowercased())"
        case .paperless(let connection, let document): "paperless:\(connection.uuidString.lowercased()):\(document.id)"
        }
    }
    public init(kind: Kind, title: String, subtitle: String) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }
}

/// The catalogue answers at once; Paperless is asked after three characters
/// and a pause, and a late answer to an earlier query never lands.
@MainActor public final class FilePickerSearch: ObservableObject {
    public static let limit = 30
    public static let paperlessMinimumQuery = 3
    @Published public private(set) var results: [FilePick] = []
    @Published public private(set) var failure: String?
    private let catalogue: @MainActor () -> [FileCatalogueItem]
    private let paperless: @Sendable (UUID, String) async throws -> [PaperlessDocument]
    private let connections: @MainActor () -> [UUID]
    private let debounce: Duration
    private var generation = 0
    private var task: Task<Void, Never>?

    public init(
        catalogue: @escaping @MainActor () -> [FileCatalogueItem],
        paperless: @escaping @Sendable (UUID, String) async throws -> [PaperlessDocument],
        connections: @escaping @MainActor () -> [UUID], debounce: Duration = .milliseconds(400)
    ) {
        self.catalogue = catalogue
        self.paperless = paperless
        self.connections = connections
        self.debounce = debounce
    }

    public func update(query: String) {
        generation += 1
        let token = generation
        task?.cancel()
        task = nil
        failure = nil
        let local = FileRanking.rank(catalogue(), query: query, limit: Self.limit, title: \.name, subtitle: { $0.sourceTitle ?? "" }).map {
            FilePick(kind: .archive($0), title: $0.name, subtitle: "Файл · " + ($0.sourceTitle ?? Self.serviceTitle($0.service)))
        }
        results = local
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = connections()
        guard trimmed.count >= Self.paperlessMinimumQuery, !targets.isEmpty else { return }
        let paperless = paperless, debounce = debounce
        task = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled, let self, self.generation == token else { return }
            var remote: [FilePick] = []
            var problem: String?
            for connection in targets {
                do {
                    let documents = try await paperless(connection, trimmed)
                    remote += documents.map {
                        FilePick(kind: .paperless(connectionID: connection, document: $0), title: $0.title, subtitle: "Paperless")
                    }
                } catch {
                    problem =
                        (error as? FilesFailure)?.errorDescription ?? (error as? LocalizedError)?.errorDescription
                        ?? "Paperless недоступен."
                }
            }
            guard !Task.isCancelled, self.generation == token else { return }
            self.results = local + remote.prefix(Self.limit)
            self.failure = problem
        }
    }

    /// Waits for the Paperless query this search started, if any.
    public func settle() async {
        while let current = task {
            await current.value
            if task == current { task = nil }
        }
    }

    private static func serviceTitle(_ service: String) -> String {
        switch service {
        case "mail": "Почта"
        case "telegram": "Telegram"
        case "whatsapp": "WhatsApp"
        case "teams": "Teams"
        default: service
        }
    }
}
