import Foundation
import Combine

public enum TelegramComposerForwardPhase: Equatable, Sendable { case idle, loading, ready, unavailable, committing, uncertain }
public struct TelegramComposerForwardPreview: Equatable, Sendable, Identifiable {
    public let id: String
    public let author: String
    public let text: String
    public let formattedText: TelegramFormattedText?
    public let canCopy: Bool
    public let hasCaption: Bool
    public init(id: String, author: String, text: String, formattedText: TelegramFormattedText?, canCopy: Bool, hasCaption: Bool = false) {
        self.id = id; self.author = author; self.text = text; self.formattedText = formattedText; self.canCopy = canCopy; self.hasCaption = hasCaption
    }
}
@MainActor protocol TelegramComposerForwardLease: AnyObject { func cancel() }
@MainActor protocol TelegramComposerForwardProvider: AnyObject {
    var accountID: Int64 { get }
    func resolve(draft: TelegramComposerDraft, completion: @escaping @MainActor ([TelegramComposerForwardPreview]?) -> Void) -> any TelegramComposerForwardLease
    func submit(draft: TelegramComposerDraft, receive: @escaping @MainActor (TelegramComposerForwardEvent) -> Void) -> any TelegramComposerForwardLease
    func consumeAccepted(draft: TelegramComposerDraft, completion: @escaping @MainActor (TelegramComposerDraft?) -> Void) -> any TelegramComposerForwardLease
}
enum TelegramComposerForwardEvent { case committing(TelegramComposerDraft), receiptAccepted(TelegramComposerDraft), rejected(TelegramComposerDraft), accepted(TelegramComposerDraft), uncertain }

@MainActor public final class TelegramComposerForwardController: ObservableObject {
    @Published public private(set) var phase: TelegramComposerForwardPhase = .idle
    @Published public private(set) var previews: [TelegramComposerForwardPreview] = []
    @Published public private(set) var error: String?
    var didUpdateDraft: ((TelegramComposerDraft, TelegramComposerDraft) -> Void)?
    private var provider: (any TelegramComposerForwardProvider)?
    private var draft: TelegramComposerDraft?
    private var lease: (any TelegramComposerForwardLease)?
    private var deadline: Task<Void, Never>?
    private var request = UUID()
    public init() {}
    func bind(_ provider: (any TelegramComposerForwardProvider)?) {
        cancel(); self.provider = provider
    }
    func select(_ draft: TelegramComposerDraft?, initial: [TelegramComposerForwardPreview]? = nil) {
        if self.draft == draft { return }
        if let draft, let current = self.draft, draft.accountID == current.accountID,
           draft.chatID == current.chatID, draft.forwardIntent?.id == current.forwardIntent?.id,
           draft.forwardDisposition == current.forwardDisposition {
            if phase == .committing || phase == .uncertain { return }
            if phase == .ready { self.draft = draft; return }
        }
        cancel()
        guard let draft, draft.isValid, draft.forwardIntent != nil, provider?.accountID == draft.accountID else { return }
        self.draft = draft
        if let initial { previews = initial }
        switch draft.forwardDisposition {
        case .submissionStarted: phase = .uncertain; error = "Результат отправки неизвестен. Автоматического повтора нет."
        case .accepted: consume(draft)
        case .prepared: resolve(draft)
        case nil: phase = .unavailable
        }
    }
    private func resolve(_ draft: TelegramComposerDraft) {
        guard let provider else { return }
        let id = UUID(); request = id; phase = .loading; error = nil
        armDeadline(id: id, committing: false)
        let returned = provider.resolve(draft: draft) { [weak self] values in
            guard let self, self.request == id else { return }
            self.deadline?.cancel(); self.deadline = nil
            self.request = UUID()
            if let values { self.previews = values; self.phase = .ready; self.error = nil }
            else { self.phase = .unavailable; self.error = "Исходные сообщения или получатель сейчас недоступны." }
            self.releaseLease()
        }
        install(returned, id: id, pending: phase == .loading)
    }
    @discardableResult func submit(_ draft: TelegramComposerDraft) -> Bool {
        guard phase == .ready, self.draft == draft, draft.forwardDisposition == .prepared,
              let provider, provider.accountID == draft.accountID else { return false }
        let id = UUID(); request = id; phase = .committing; error = nil
        armDeadline(id: id, committing: true)
        let returned = provider.submit(draft: draft) { [weak self] event in
            guard let self, self.request == id else { return }
            switch event {
            case let .committing(started):
                self.draft = started
                self.didUpdateDraft?(draft, started)
            case let .receiptAccepted(accepted):
                self.draft = accepted
                self.didUpdateDraft?(draft, accepted)
            case let .accepted(replacement):
                self.deadline?.cancel(); self.deadline = nil
                self.request = UUID(); self.releaseLease(); self.draft = replacement
                self.phase = .idle; self.previews = []; self.error = nil
                self.didUpdateDraft?(draft, replacement)
            case let .rejected(replacement):
                self.deadline?.cancel(); self.deadline = nil
                self.request = UUID(); self.releaseLease(); self.draft = replacement
                self.phase = .unavailable; self.error = "Пересылка не поставлена в очередь. Проверьте сообщения и получателя."
                self.didUpdateDraft?(draft, replacement)
            case .uncertain:
                self.deadline?.cancel(); self.deadline = nil
                self.phase = .uncertain; self.error = "Результат отправки неизвестен. Не повторяйте пересылку."
            }
        }
        install(returned, id: id, pending: phase == .committing || phase == .uncertain)
        return true
    }
    private func consume(_ draft: TelegramComposerDraft) {
        guard let provider else { return }
        let id = UUID(); request = id; phase = .committing
        armDeadline(id: id, committing: true)
        let returned = provider.consumeAccepted(draft: draft) { [weak self] replacement in
            guard let self, self.request == id else { return }
            self.deadline?.cancel(); self.deadline = nil; self.releaseLease()
            if let replacement {
                self.request = UUID(); self.draft = replacement; self.phase = .idle; self.previews = []; self.error = nil
                self.didUpdateDraft?(draft, replacement)
            } else { self.phase = .uncertain; self.error = "Очередь приняла пересылку, но подтвердить очистку черновика не удалось." }
        }
        install(returned, id: id, pending: phase == .committing)
    }
    public func retry() {
        guard let draft else { return }
        if case .accepted = draft.forwardDisposition { consume(draft) }
        else if phase == .unavailable { resolve(draft) }
    }
    public func cancel() {
        request = UUID(); deadline?.cancel(); deadline = nil; releaseLease()
        draft = nil; previews = []; error = nil; phase = .idle
    }
    private func releaseLease() { let old = lease; lease = nil; old?.cancel() }
    private func install(_ returned: any TelegramComposerForwardLease, id: UUID, pending: Bool) {
        if request == id && pending { lease = returned } else { returned.cancel() }
    }
    private func armDeadline(id: UUID, committing: Bool) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.request == id else { return }
            self.expire()
        }
    }
    func expire() {
        if phase == .loading { request = UUID(); releaseLease(); phase = .unavailable; error = "Не удалось проверить пересылку вовремя." }
        else if phase == .committing { phase = .uncertain; error = "Результат отправки неизвестен. Не повторяйте пересылку." }
        deadline?.cancel(); deadline = nil
    }
    isolated deinit { deadline?.cancel(); lease?.cancel() }
}
