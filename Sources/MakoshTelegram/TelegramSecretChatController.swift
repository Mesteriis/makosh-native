import Foundation
import Combine
import TelegramCore
import Postbox

private func secretRevisionValid(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}
public struct TelegramSecretCreationBasis: Equatable, Sendable {
    public let accountID: Int64, peerID: Int64
    public let title: String, username: String?
    public let canCreate: Bool, premiumRequired: Bool
    public let revision: String
    public var existingSecretID: Int64? = nil
    var isValid: Bool {
        telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser
            && telegramManagementPeerID(peerID)?.namespace == Namespaces.Peer.CloudUser && peerID != accountID
            && !title.isEmpty && title.utf16.count <= 512 && !title.contains("\0") && secretRevisionValid(revision)
            && (username.map { $0.utf16.count <= 256 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) } ?? true)
            && (existingSecretID.map { telegramSecretPeerID($0) != nil } ?? true)
    }
}
public struct TelegramSecretSessionSnapshot: Equatable, Sendable {
    public let accountID: Int64, chatID: Int64, regularPeerID: Int64
    public let title: String
    public let state: TelegramSecretConversation.State
    public let verification: TelegramSecretChatVerification?
    public let layer: Int32?, ttl: Int32?
    public let keyAvailable: Bool
    public let revision: String
    var isValid: Bool {
        guard telegramManagementPeerID(accountID)?.namespace == Namespaces.Peer.CloudUser, telegramSecretPeerID(chatID) != nil,
              telegramManagementPeerID(regularPeerID)?.namespace == Namespaces.Peer.CloudUser, regularPeerID != accountID,
              !title.isEmpty, title.utf16.count <= 512, !title.contains("\0"), secretRevisionValid(revision),
              ttl.map({ $0 > 0 }) ?? true, layer.map({ [8, 46, 73, 101, 144].contains($0) }) ?? true else { return false }
        if state != .active { return !keyAvailable && verification == nil && layer == nil }
        return !keyAvailable || (verification != nil && layer != nil)
    }
    public var canSetTTL: Bool { isValid && state == .active && keyAvailable && verification != nil && layer != nil }
}
struct TelegramSecretTTLReceipt: Equatable, Sendable {
    let accountID: Int64, chatID: Int64
    let previousTTL: Int32?, timeout: Int32?
    let sessionRevision: String
    let namespace: Int32, messageID: Int32
    func matches(basis: TelegramSecretSessionSnapshot, timeout: Int32?) -> Bool {
        accountID == basis.accountID && chatID == basis.chatID && previousTTL == basis.ttl && self.timeout == timeout
            && sessionRevision == basis.revision && namespace == Namespaces.Message.Local && messageID > 0
    }
}
enum TelegramSecretChatError: Error { case failed, unavailable, changed, premiumRequired, limitExceeded, uncertain }
enum TelegramSecretCreationEvent { case committing, created(TelegramSecretSessionSnapshot), failed(TelegramSecretChatError) }
enum TelegramSecretTTLEvent { case committing, queued(TelegramSecretTTLReceipt), failed(TelegramSecretChatError) }
@MainActor protocol TelegramSecretChatRequest: AnyObject { func cancel() }
@MainActor protocol TelegramSecretChatProvider: AnyObject {
    var accountID: Int64 { get }
    func loadCreation(peerID: Int64, receive: @escaping @MainActor (Result<TelegramSecretCreationBasis, TelegramSecretChatError>) -> Void) -> any TelegramSecretChatRequest
    func create(basis: TelegramSecretCreationBasis, receive: @escaping @MainActor (TelegramSecretCreationEvent) -> Bool) -> any TelegramSecretChatRequest
    func observeSession(chatID: Int64, receive: @escaping @MainActor (Result<TelegramSecretSessionSnapshot, TelegramSecretChatError>) -> Void) -> any TelegramSecretChatRequest
    func setTTL(basis: TelegramSecretSessionSnapshot, timeout: Int32?, receive: @escaping @MainActor (TelegramSecretTTLEvent) -> Bool) -> any TelegramSecretChatRequest
}

@MainActor public final class TelegramSecretChatController: ObservableObject {
    public enum CreationPhase: Equatable { case idle, validating, committing, created, changed, failed, premiumRequired, limitExceeded, uncertain }
    public enum TTLPhase: Equatable { case idle, validating, committing, queued, changed, failed, uncertain }
    @Published public private(set) var creationBasis: TelegramSecretCreationBasis?
    @Published public private(set) var creationStatus: TelegramSearchStatus = .idle
    @Published public private(set) var creationPhase: CreationPhase = .idle
    @Published public private(set) var createdSession: TelegramSecretSessionSnapshot?
    @Published public private(set) var creationContextID = UUID()
    @Published public private(set) var session: TelegramSecretSessionSnapshot?
    @Published public private(set) var sessionStatus: TelegramSearchStatus = .idle
    @Published public private(set) var ttlPhase: TTLPhase = .idle
    @Published public private(set) var sessionContextID = UUID()
    public private(set) var creationPeerID: Int64?, selectedSecretID: Int64?
    public var accountID: Int64? { provider?.accountID }
    public var isCreating: Bool { creationPhase == .validating || creationPhase == .committing }
    public var isSettingTTL: Bool { ttlPhase == .validating || ttlPhase == .committing }
    var didCreate: (@MainActor (TelegramSecretSessionSnapshot, UUID) -> Void)?
    private var provider: (any TelegramSecretChatProvider)?
    private var creationRead: (any TelegramSecretChatRequest)?, creationWrite: (any TelegramSecretChatRequest)?
    private var sessionRead: (any TelegramSecretChatRequest)?, ttlWrite: (any TelegramSecretChatRequest)?
    private var creationReadID: UUID?, creationWriteID: UUID?, sessionReadID: UUID?, ttlWriteID: UUID?
    private var creationReadDeadline: Task<Void, Never>?, creationWriteDeadline: Task<Void, Never>?
    private var sessionReadDeadline: Task<Void, Never>?, ttlWriteDeadline: Task<Void, Never>?
    private struct Destination: Hashable { let accountID: Int64, peerID: Int64 }
    private var unknownCreations: Set<Destination> = [], unknownTTLs: Set<Destination> = []
    private var lastTTLReceipt: TelegramSecretTTLReceipt?
    public init() {}
    isolated deinit {
        creationRead?.cancel(); creationWrite?.cancel(); sessionRead?.cancel(); ttlWrite?.cancel()
        creationReadDeadline?.cancel(); creationWriteDeadline?.cancel(); sessionReadDeadline?.cancel(); ttlWriteDeadline?.cancel()
    }
    func bind(_ provider: (any TelegramSecretChatProvider)?) { closeCreation(); closeSession(); self.provider = provider }
    public func openCreation(peerID: Int64) {
        closeCreation()
        guard telegramManagementPeerID(peerID)?.namespace == Namespaces.Peer.CloudUser, peerID != accountID, let accountID else { creationStatus = .failed; return }
        creationPeerID = peerID
        if unknownCreations.contains(.init(accountID: accountID, peerID: peerID)) { creationPhase = .uncertain }
        readCreation(reconcile: false)
    }
    public func closeCreation() {
        if creationPhase == .committing { retainUnknownCreation() }
        creationReadID = nil; creationWriteID = nil; creationContextID = UUID()
        creationRead?.cancel(); creationWrite?.cancel(); creationRead = nil; creationWrite = nil
        creationReadDeadline?.cancel(); creationWriteDeadline?.cancel(); creationReadDeadline = nil; creationWriteDeadline = nil
        creationPeerID = nil; creationBasis = nil; createdSession = nil; creationStatus = .idle; creationPhase = .idle
    }
    public func refreshCreation() {
        guard !isCreating else { return }; creationContextID = UUID(); createdSession = nil; readCreation(reconcile: true)
    }
    private func readCreation(reconcile: Bool) {
        creationReadID = nil; creationRead?.cancel(); creationRead = nil; creationReadDeadline?.cancel()
        guard let provider, let peerID = creationPeerID else { creationStatus = .failed; return }
        let token = UUID(), context = creationContextID
        creationReadID = token; creationStatus = .loading
        creationReadDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.creationReadID == token else { return }
            self.creationReadID = nil; self.creationRead?.cancel(); self.creationRead = nil; self.creationStatus = .timedOut
        }
        let request = provider.loadCreation(peerID: peerID) { [weak self] result in
            guard let self, self.creationReadID == token, self.creationContextID == context, self.accountID == provider.accountID else { return }
            self.creationReadID = nil; self.creationReadDeadline?.cancel(); self.creationReadDeadline = nil
            self.creationRead?.cancel(); self.creationRead = nil
            guard case let .success(basis) = result, basis.isValid, basis.accountID == provider.accountID, basis.peerID == peerID else { self.creationStatus = .failed; return }
            self.creationBasis = basis; self.creationStatus = .ready
            if reconcile { self.unknownCreations.remove(.init(accountID: basis.accountID, peerID: peerID)); self.creationPhase = .idle }
        }
        if creationReadID == token { creationRead = request } else { request.cancel() }
    }
    @discardableResult public func create(basis: TelegramSecretCreationBasis, contextID: UUID) -> Bool {
        guard contextID == creationContextID, creationStatus == .ready, !isCreating, creationPhase != .uncertain,
              let provider, provider.accountID == basis.accountID, creationBasis == basis, basis.isValid, basis.canCreate else { return false }
        let token = UUID(); creationWriteID = token; creationPhase = .validating; createdSession = nil
        creationWriteDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.creationWriteID == token else { return }; self.timeoutCreation()
        }
        let request = provider.create(basis: basis) { [weak self] event in
            guard let self, self.creationWriteID == token, self.creationContextID == contextID, self.accountID == basis.accountID else { return false }
            switch event {
            case .committing: guard self.creationPhase == .validating else { return false }; self.creationPhase = .committing
            case let .created(value):
                guard self.creationPhase == .committing, value.isValid, value.accountID == basis.accountID,
                      value.regularPeerID == basis.peerID, value.state != .terminated else { self.markCreationUnknown(); return true }
                self.finishCreation(.created); self.createdSession = value; self.didCreate?(value, contextID)
            case .failed(.premiumRequired): self.finishCreation(.premiumRequired)
            case .failed(.limitExceeded): self.finishCreation(.limitExceeded)
            case .failed(.uncertain): self.markCreationUnknown()
            case .failed(.changed): if self.creationPhase == .committing { self.markCreationUnknown() } else { self.finishCreation(.changed) }
            case .failed: if self.creationPhase == .committing { self.markCreationUnknown() } else { self.finishCreation(.failed) }
            }
            return true
        }
        if creationWriteID == token { creationWrite = request } else { request.cancel() }; return true
    }
    public func cancelCreationValidation() { guard creationPhase == .validating else { return }; finishCreation(.idle) }
    private func retainUnknownCreation() {
        if let accountID, let creationPeerID { unknownCreations.insert(.init(accountID: accountID, peerID: creationPeerID)) }
    }
    private func finishCreation(_ phase: CreationPhase) {
        creationWriteID = nil; creationWrite?.cancel(); creationWrite = nil; creationWriteDeadline?.cancel(); creationWriteDeadline = nil; creationPhase = phase
    }
    private func markCreationUnknown() { retainUnknownCreation(); finishCreation(.uncertain) }
    func timeoutCreation() { guard creationWriteID != nil else { return }; if creationPhase == .committing { markCreationUnknown() } else { finishCreation(.failed) } }

    public func selectSession(chatID: Int64?) {
        closeSession()
        guard let chatID else { return }
        guard telegramSecretPeerID(chatID) != nil, let accountID else { sessionStatus = .failed; return }
        selectedSecretID = chatID
        if unknownTTLs.contains(.init(accountID: accountID, peerID: chatID)) { ttlPhase = .uncertain }
        observeSession(reconcile: false)
    }
    private func closeSession() {
        if ttlPhase == .committing { retainUnknownTTL() }
        sessionReadID = nil; ttlWriteID = nil; sessionContextID = UUID()
        sessionRead?.cancel(); ttlWrite?.cancel(); sessionRead = nil; ttlWrite = nil
        sessionReadDeadline?.cancel(); ttlWriteDeadline?.cancel(); sessionReadDeadline = nil; ttlWriteDeadline = nil
        selectedSecretID = nil; session = nil; sessionStatus = .idle; ttlPhase = .idle; lastTTLReceipt = nil
    }
    public func refreshSession() {
        guard !isSettingTTL else { return }; sessionContextID = UUID(); observeSession(reconcile: true)
    }
    private func observeSession(reconcile: Bool) {
        sessionReadID = nil; sessionRead?.cancel(); sessionRead = nil; sessionReadDeadline?.cancel()
        guard let provider, let chatID = selectedSecretID else { sessionStatus = .failed; return }
        let token = UUID(), context = sessionContextID
        sessionReadID = token; sessionStatus = .loading
        var pendingReconciliation = reconcile
        sessionReadDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.sessionReadID == token, self.sessionStatus == .loading else { return }
            self.sessionReadID = nil; self.sessionRead?.cancel(); self.sessionRead = nil; self.sessionStatus = .timedOut
        }
        let request = provider.observeSession(chatID: chatID) { [weak self] result in
            guard let self, self.sessionReadID == token, self.sessionContextID == context, self.accountID == provider.accountID else { return }
            self.sessionReadDeadline?.cancel(); self.sessionReadDeadline = nil
            guard case let .success(value) = result, value.isValid, value.accountID == provider.accountID, value.chatID == chatID else { self.sessionStatus = .failed; return }
            self.session = value; self.sessionStatus = .ready
            if pendingReconciliation {
                pendingReconciliation = false
                self.unknownTTLs.remove(.init(accountID: value.accountID, peerID: chatID))
                self.lastTTLReceipt = nil
                if self.ttlPhase == .uncertain || self.ttlPhase == .queued { self.ttlPhase = .idle }
            }
        }
        if sessionReadID == token { sessionRead = request } else { request.cancel() }
    }
    public func canSetTTL(_ timeout: Int32?) -> Bool {
        guard let session, session.canSetTTL, sessionStatus == .ready, !isSettingTTL, ttlPhase != .uncertain,
              timeout.map({ $0 > 0 }) ?? true, timeout != session.ttl else { return false }
        if ttlPhase == .queued, let lastTTLReceipt, session.ttl != lastTTLReceipt.timeout { return false }
        return true
    }
    @discardableResult public func setTTL(_ timeout: Int32?, basis: TelegramSecretSessionSnapshot, contextID: UUID) -> Bool {
        guard contextID == sessionContextID, let provider, provider.accountID == basis.accountID,
              session == basis, basis.isValid, canSetTTL(timeout) else { return false }
        let token = UUID(); ttlWriteID = token; ttlPhase = .validating; lastTTLReceipt = nil
        ttlWriteDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.ttlWriteID == token else { return }; self.timeoutTTL()
        }
        let request = provider.setTTL(basis: basis, timeout: timeout) { [weak self] event in
            guard let self, self.ttlWriteID == token, self.sessionContextID == contextID, self.accountID == basis.accountID else { return false }
            switch event {
            case .committing: guard self.ttlPhase == .validating else { return false }; self.ttlPhase = .committing
            case let .queued(receipt):
                guard self.ttlPhase == .committing, receipt.matches(basis: basis, timeout: timeout) else { self.markTTLUnknown(); return true }
                self.lastTTLReceipt = receipt; self.finishTTL(.queued)
            case .failed(.uncertain): self.markTTLUnknown()
            case .failed(.changed): if self.ttlPhase == .committing { self.markTTLUnknown() } else { self.finishTTL(.changed) }
            case .failed: if self.ttlPhase == .committing { self.markTTLUnknown() } else { self.finishTTL(.failed) }
            }
            return true
        }
        if ttlWriteID == token { ttlWrite = request } else { request.cancel() }; return true
    }
    public func cancelTTLValidation() { guard ttlPhase == .validating else { return }; finishTTL(.idle) }
    private func retainUnknownTTL() {
        if let accountID, let selectedSecretID { unknownTTLs.insert(.init(accountID: accountID, peerID: selectedSecretID)) }
    }
    private func finishTTL(_ phase: TTLPhase) {
        ttlWriteID = nil; ttlWrite?.cancel(); ttlWrite = nil; ttlWriteDeadline?.cancel(); ttlWriteDeadline = nil; ttlPhase = phase
    }
    private func markTTLUnknown() { retainUnknownTTL(); finishTTL(.uncertain) }
    func timeoutTTL() { guard ttlWriteID != nil else { return }; if ttlPhase == .committing { markTTLUnknown() } else { finishTTL(.failed) } }
}
