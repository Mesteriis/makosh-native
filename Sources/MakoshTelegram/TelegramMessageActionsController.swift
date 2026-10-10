import Foundation
import Combine

public struct TelegramMessageActionMetadata: Equatable, Sendable {
    public let peerID: Int64
    public let namespace: Int32
    public let messageID: Int32
    public let fingerprint: String
    public let text: String
    public let authorID: Int64?
    public let canEditAsAdmin: Bool
    public let canDeleteAsAdmin: Bool
    public let canDeleteIncomingPrivate: Bool
    public let migrationChatID: Int64?
    public let allowsEmptyEdit: Bool
    public let editLimit: Int
    public let threadID: Int64?
    public let formattedText: TelegramFormattedText?
    public let canEditOutgoingChannel: Bool
    public let canDeleteOutgoingChannel: Bool
    public let canReply: Bool
    public let canEdit: Bool
    public let canForward: Bool
    public let canCopy: Bool
    public let canDeleteLocally: Bool
    public let canDeleteForEveryone: Bool
    public init(peerID: Int64, namespace: Int32, messageID: Int32, fingerprint: String, text: String,
                authorID: Int64?, canReply: Bool, canEdit: Bool, canForward: Bool,
                canDeleteLocally: Bool, canDeleteForEveryone: Bool, canEditAsAdmin: Bool = false,
                canDeleteAsAdmin: Bool = false, canDeleteIncomingPrivate: Bool = false, migrationChatID: Int64? = nil, allowsEmptyEdit: Bool = false, editLimit: Int = 4096, threadID: Int64? = nil, formattedText: TelegramFormattedText? = nil,
                canEditOutgoingChannel: Bool = false, canDeleteOutgoingChannel: Bool = false, canCopy: Bool = false) {
        self.peerID = peerID; self.namespace = namespace; self.messageID = messageID
        self.fingerprint = fingerprint; self.text = text; self.authorID = authorID
        self.canEditAsAdmin = canEditAsAdmin; self.canDeleteAsAdmin = canDeleteAsAdmin; self.canDeleteIncomingPrivate = canDeleteIncomingPrivate; self.migrationChatID = migrationChatID; self.allowsEmptyEdit = allowsEmptyEdit; self.editLimit = editLimit; self.threadID = threadID; self.formattedText = formattedText
        self.canEditOutgoingChannel = canEditOutgoingChannel; self.canDeleteOutgoingChannel = canDeleteOutgoingChannel
        self.canReply = canReply; self.canEdit = canEdit; self.canForward = canForward; self.canCopy = canCopy
        self.canDeleteLocally = canDeleteLocally; self.canDeleteForEveryone = canDeleteForEveryone
    }
}

public struct TelegramMessageActionSource: Equatable, Sendable {
    public let metadata: TelegramMessageActionMetadata
    public let accountID: Int64
    public let chatID: Int64
    public var peerID: Int64 { metadata.peerID }
    public var namespace: Int32 { metadata.namespace }
    public var messageID: Int32 { metadata.messageID }
    public var threadID: Int64? { metadata.threadID }
    public var editLimit: Int { metadata.editLimit }
    public var fingerprint: String { metadata.fingerprint }
    public var text: String { metadata.text }
    public var canReply: Bool { metadata.canReply }
    public var canEdit: Bool { metadata.canEdit && (metadata.authorID == accountID || metadata.canEditAsAdmin || metadata.canEditOutgoingChannel) }
    public var canForward: Bool { metadata.canForward }
    public var canCopy: Bool { metadata.canCopy }
    public var canDeleteLocally: Bool { metadata.canDeleteLocally }
    public var canDeleteForEveryone: Bool { metadata.canDeleteForEveryone && (metadata.authorID == accountID || metadata.canDeleteAsAdmin || metadata.canDeleteIncomingPrivate || metadata.canDeleteOutgoingChannel) }
    public init(metadata: TelegramMessageActionMetadata, accountID: Int64, chatID: Int64) {
        self.metadata = metadata; self.accountID = accountID; self.chatID = chatID
    }
    public init(accountID: Int64, chatID: Int64, peerID: Int64, namespace: Int32, messageID: Int32,
                fingerprint: String, text: String, canReply: Bool, canEdit: Bool, canForward: Bool,
                canDeleteLocally: Bool, canDeleteForEveryone: Bool, canCopy: Bool = false) {
        self.init(metadata: .init(peerID: peerID, namespace: namespace, messageID: messageID,
            fingerprint: fingerprint, text: text, authorID: accountID, canReply: canReply, canEdit: canEdit,
            canForward: canForward, canDeleteLocally: canDeleteLocally, canDeleteForEveryone: canDeleteForEveryone, canCopy: canCopy),
            accountID: accountID, chatID: chatID)
    }
}

public enum TelegramMessageAction: Equatable, Sendable {
    case reply(String), replyFormatted(TelegramFormattedText), edit(String), editFormatted(TelegramFormattedText), forward(destinationChatID: Int64), delete(forEveryone: Bool)
}
public enum TelegramMessageActionPhase: Equatable, Sendable {
    case idle, validating, committing, queued, applied, rejected, uncertain
}
@MainActor protocol TelegramMessageActionsLease: AnyObject { func cancel() }
@MainActor protocol TelegramMessageActionsProvider: AnyObject {
    var accountID: Int64 { get }
    func start(action: TelegramMessageAction, source: TelegramMessageActionSource,
               receive: @escaping @MainActor (TelegramMessageActionEvent) -> Void) -> any TelegramMessageActionsLease
}
enum TelegramMessageActionEvent { case committing, queued, applied, rejected, uncertain }

func telegramMessageActionAllowed(_ action: TelegramMessageAction, source: TelegramMessageActionSource) -> Bool {
    guard (source.chatID == source.peerID || source.metadata.migrationChatID == source.chatID), !source.fingerprint.isEmpty else { return false }
    switch action {
    case let .reply(text): return source.canReply && (try? TelegramFormattedText(text: text)).map { telegramFormattedTextCanSend($0) } == true
    case let .replyFormatted(value): return source.canReply && telegramFormattedTextCanSend(value)
    case let .edit(text):
        return source.canEdit && (source.metadata.formattedText?.entities.isEmpty ?? true) &&
            text.utf16.count <= source.editLimit && !text.utf8.elementsEqual(source.text.utf8) &&
            (!text.isEmpty || source.metadata.allowsEmptyEdit)
    case let .editFormatted(formatted):
        guard source.canEdit, formatted.isEditable, source.metadata.formattedText?.isEditable != false else { return false }
        let original = source.metadata.formattedText ?? (try? TelegramFormattedText(text: source.text))
        return formatted.text.utf16.count <= source.editLimit && formatted != original &&
            (!formatted.text.isEmpty || source.metadata.allowsEmptyEdit)
    case .forward: return source.canForward
    case let .delete(everyone): return everyone ? source.canDeleteForEveryone : source.canDeleteLocally
    }
}

/// Retains the submitted composition and target through rejection/uncertainty.
/// Queued means a local engine transaction, never server delivery or recall.
@MainActor public final class TelegramMessageActionsController: ObservableObject {
    @Published public private(set) var phase: TelegramMessageActionPhase = .idle
    @Published public private(set) var source: TelegramMessageActionSource?
    @Published public private(set) var action: TelegramMessageAction?
    public var isBusy: Bool { phase == .validating || phase == .committing }
    var didQueue: ((TelegramMessageAction, TelegramMessageActionSource) -> Void)?
    var didApply: ((TelegramMessageAction, TelegramMessageActionSource) -> Void)?
    private var provider: (any TelegramMessageActionsProvider)?
    private var lease: (any TelegramMessageActionsLease)?
    private var token: UUID?
    private var deadline: Task<Void, Never>?
    public init() {}
    func bind(provider: (any TelegramMessageActionsProvider)?) { reset(); self.provider = provider }
    @discardableResult public func perform(_ action: TelegramMessageAction, source: TelegramMessageActionSource) -> Bool {
        guard !isBusy, phase != .uncertain else { return false }
        self.source = source; self.action = action
        guard let provider, provider.accountID == source.accountID,
              telegramMessageActionAllowed(action, source: source) else { phase = .rejected; return false }
        let id = UUID(); token = id; phase = .validating
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard self?.token == id else { return }; self?.timeout()
        }
        let result = provider.start(action: action, source: source) { [weak self] event in
            guard let self, self.token == id, self.isBusy else { return }
            switch event {
            case .committing: self.phase = .committing
            case .queued:
                self.complete(.queued)
                self.didQueue?(action, source)
            case .applied:
                self.complete(.applied)
                self.didApply?(action, source)
            case .rejected: self.complete(.rejected)
            case .uncertain: self.complete(.uncertain)
            }
        }
        if token == id && isBusy { lease = result } else { result.cancel() }
        return true
    }
    public func cancel() { guard isBusy else { return }; complete(phase == .committing ? .uncertain : .rejected) }
    func timeout() { cancel() }
    private func complete(_ phase: TelegramMessageActionPhase) {
        token = nil; deadline?.cancel(); deadline = nil
        self.phase = phase
        let old = lease; lease = nil; old?.cancel()
    }
    public func reset() { complete(.idle); source = nil; action = nil; provider = nil }
    isolated deinit { deadline?.cancel(); lease?.cancel() }
}
