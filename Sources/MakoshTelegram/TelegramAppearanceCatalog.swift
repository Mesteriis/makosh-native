import Foundation
import Combine

public enum TelegramCloudAppearanceKind: Equatable, Sendable {
    case theme(TelegramCloudPalette), wallpaper(TelegramLocalWallpaper), image(Data)
    case pattern(TelegramPreparedPattern)
    case downloadTheme, downloadWallpaper, unavailable(String)
}
public struct TelegramCloudAppearanceChoice: Identifiable, Equatable, Sendable {
    public let id, title: String
    public let kind: TelegramCloudAppearanceKind
}
public struct TelegramAppearanceCatalogSnapshot: Equatable, Sendable {
    public let accountID: Int64
    public let choices: [TelegramCloudAppearanceChoice]
    var isValid: Bool {
        choices.count <= 2048 && Set(choices.map(\.id)).count == choices.count && choices.allSatisfy { item in
            guard !item.id.isEmpty, item.id.utf8.count <= 128, !item.title.isEmpty, item.title.utf8.count <= 256,
                  ![item.id,item.title].contains(where:{ $0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }) else { return false }
            switch item.kind { case let .theme(value): return value.isValid; case let .wallpaper(value): return value.isValid; case .image,.pattern: return false; default: return true }
        }
    }
}
@MainActor protocol TelegramAppearanceCatalogProvider: AnyObject {
    var accountID: Int64 { get }
    func load(receive: @escaping @MainActor (Result<TelegramAppearanceCatalogSnapshot,TelegramAppearanceError>) -> Void) -> any TelegramSessionsRequest
    func prepare(_ choice: TelegramCloudAppearanceChoice, receive: @escaping @MainActor (Result<TelegramCloudAppearanceKind,TelegramAppearanceError>) -> Void) -> any TelegramSessionsRequest
}
@MainActor public final class TelegramAppearanceCatalogController: ObservableObject {
    public enum Phase: Equatable { case idle, loading, ready, preparing, failed }
    public struct Prepared: Identifiable {
        public let id = UUID()
        public let choice: TelegramCloudAppearanceChoice
        public let kind: TelegramCloudAppearanceKind
        public let contextID: UUID
    }
    @Published public private(set) var snapshot: TelegramAppearanceCatalogSnapshot?
    @Published public private(set) var prepared: Prepared?
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var contextID = UUID()
    private var provider: (any TelegramAppearanceCatalogProvider)?
    private var work: (any TelegramSessionsRequest)?, workID: UUID?
    private var deadline: Task<Void,Never>?
    public init() {}
    isolated deinit { work?.cancel(); deadline?.cancel() }
    func bind(_ provider: (any TelegramAppearanceCatalogProvider)?) { close(); self.provider = provider }
    public func close() {
        contextID = UUID(); workID = nil; work?.cancel(); work = nil; deadline?.cancel(); deadline = nil
        snapshot = nil; prepared = nil; phase = .idle
    }
    public func open() {
        close(); guard let provider else { phase = .failed; return }
        let context = contextID, id = UUID(), accountID = provider.accountID; workID = id; phase = .loading
        setDeadline(id)
        let request = provider.load { [weak self] result in
            guard let self, self.contextID == context, self.workID == id else { return }
            self.finishWork()
            switch result {
            case let .success(value) where value.accountID == accountID && value.isValid: self.snapshot = value; self.phase = .ready
            default: self.snapshot = nil; self.phase = .failed
            }
        }
        if workID == id { work = request } else { request.cancel() }
    }
    @discardableResult public func select(_ choice: TelegramCloudAppearanceChoice, contextID: UUID) -> Bool {
        guard self.contextID == contextID, phase == .ready, let provider, let snapshot,
              snapshot.accountID == provider.accountID, snapshot.choices.contains(choice) else { return false }
        prepared = nil
        switch choice.kind {
        case .theme, .wallpaper: prepared = .init(choice:choice,kind:choice.kind,contextID:contextID); return true
        case .downloadTheme, .downloadWallpaper: break
        default: return false
        }
        let id = UUID(); workID = id; phase = .preparing; setDeadline(id)
        let request = provider.prepare(choice) { [weak self] result in
            guard let self, self.contextID == contextID, self.workID == id else { return }
            self.finishWork()
            let kind: TelegramCloudAppearanceKind
            switch result {
            case let .success(.theme(value)) where value.isValid && choice.kind == .downloadTheme: kind = .theme(value)
            case let .success(.wallpaper(value)) where value.isValid && choice.kind == .downloadWallpaper: kind = .wallpaper(value)
            case let .success(.image(data)) where !data.isEmpty && data.count <= 8 * 1024 * 1024 && choice.kind == .downloadWallpaper: kind = .image(data)
            case let .success(.pattern(value)) where value.isValid && choice.kind == .downloadWallpaper: kind = .pattern(value)
            default: self.phase = .failed; return
            }
            self.prepared = .init(choice:choice,kind:kind,contextID:contextID); self.phase = .ready
        }
        if workID == id { work = request } else { request.cancel() }; return true
    }
    public func cancelSelection() {
        finishWork(); contextID = UUID(); prepared = nil; phase = snapshot == nil ? .idle : .ready
    }
    private func finishWork() { workID = nil; work?.cancel(); work = nil; deadline?.cancel(); deadline = nil }
    private func setDeadline(_ id: UUID) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(30)) } catch { return }
            guard let self, self.workID == id else { return }; self.finishWork(); self.phase = .failed
        }
    }
}
