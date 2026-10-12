import Foundation
import Combine
import TelegramApi

public enum TelegramPrivacyKind: String, CaseIterable, Identifiable, Sendable {
    case phoneNumber, presence, groupInvitations, voiceCalls, profilePhoto, bio, birthday, forwards, phoneDiscovery, callP2P
    public var id: String { rawValue }
}
public enum TelegramPrivacyAudience: String, CaseIterable, Identifiable, Sendable {
    case everybody, contacts, nobody
    public var id: String { rawValue }
}
public enum TelegramPrivacyRule: Equatable, Sendable {
    case everybody, contacts, nobody, denyContacts, closeFriends, premium, bots, denyBots
    case allowUsers([Int64]), denyUsers([Int64]), allowChats([Int64]), denyChats([Int64])
}
public struct TelegramPrivacySetting: Equatable, Sendable {
    public let kind: TelegramPrivacyKind
    public let rules: [TelegramPrivacyRule]
    public var audience: TelegramPrivacyAudience? {
        guard isValid else { return nil }
        let bases = rules.filter { $0.isBase }
        if bases == [.everybody] { return .everybody }
        if bases == [.contacts] || bases == [.contacts, .nobody] { return .contacts }
        if bases == [.nobody], kind != .phoneDiscovery { return .nobody }
        return nil
    }
    var isValid: Bool {
        guard !rules.isEmpty, rules.count <= 64 else { return false }
        var count = 0
        for rule in rules {
            let ids = rule.peerIDs
            guard ids.count <= 1024, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else { return false }
            count += ids.count
        }
        return count <= 4096
    }
    public func replacingAudience(_ value: TelegramPrivacyAudience) -> TelegramPrivacySetting? {
        guard let audience, audience != value, kind != .phoneDiscovery || value != .nobody else { return nil }
        var replaced = false
        let base: TelegramPrivacyRule = switch value { case .everybody: .everybody; case .contacts: .contacts; case .nobody: .nobody }
        let updated = rules.compactMap { rule -> TelegramPrivacyRule? in
            guard rule.isBase else { return rule }
            guard !replaced else { return nil }; replaced = true; return base
        }
        return .init(kind: kind, rules: updated)
    }
}
public struct TelegramPrivacyChange: Equatable, Sendable {
    public let expected: TelegramPrivacySetting
    public let audience: TelegramPrivacyAudience
    private let proposed: TelegramPrivacySetting
    public init(expected: TelegramPrivacySetting, audience: TelegramPrivacyAudience) {
        self.expected = expected; self.audience = audience; proposed = expected.replacingAudience(audience) ?? expected
    }
    public init(expected: TelegramPrivacySetting, replacement: TelegramPrivacySetting) {
        self.expected = expected; self.audience = replacement.audience ?? .contacts; proposed = replacement
    }
    public var replacement: TelegramPrivacySetting? {
        guard expected.audience != nil, proposed.audience != nil, expected.kind == proposed.kind, proposed != expected,
              expected.rules.filter({ $0.isSpecial }) == proposed.rules.filter({ $0.isSpecial }) else { return nil }
        if expected.kind == .phoneDiscovery, expected.rules.filter({ !$0.isBase }) != proposed.rules.filter({ !$0.isBase }) { return nil }
        return proposed
    }
}
extension TelegramPrivacyRule {
    var isSpecial: Bool { switch self { case .denyContacts, .closeFriends, .premium, .bots, .denyBots: true; default: false } }
    var isBase: Bool { switch self { case .everybody, .contacts, .nobody: true; default: false } }
    var peerIDs: [Int64] { switch self { case let .allowUsers(ids), let .denyUsers(ids), let .allowChats(ids), let .denyChats(ids): ids; default: [] } }
}
func telegramPrivacySetting(_ response: Api.account.PrivacyRules, kind: TelegramPrivacyKind) -> TelegramPrivacySetting? {
    guard case let .privacyRules(rules, _, _) = response, rules.count <= 64 else { return nil }
    let values: [TelegramPrivacyRule] = rules.map { rule in
        switch rule {
        case .privacyValueAllowAll: .everybody
        case .privacyValueAllowContacts: .contacts
        case .privacyValueDisallowAll: .nobody
        case .privacyValueDisallowContacts: .denyContacts
        case .privacyValueAllowCloseFriends: .closeFriends
        case .privacyValueAllowPremium: .premium
        case .privacyValueAllowBots: .bots
        case .privacyValueDisallowBots: .denyBots
        case let .privacyValueAllowUsers(ids): .allowUsers(ids)
        case let .privacyValueDisallowUsers(ids): .denyUsers(ids)
        case let .privacyValueAllowChatParticipants(ids): .allowChats(ids)
        case let .privacyValueDisallowChatParticipants(ids): .denyChats(ids)
        }
    }
    let value = TelegramPrivacySetting(kind: kind, rules: values)
    return value.isValid ? value : nil
}
func telegramAdmitPrivacyChange(accountID: Int64, expectedAccountID: Int64, current: TelegramPrivacySetting, change: TelegramPrivacyChange) -> Bool {
    accountID == expectedAccountID && current == change.expected && change.replacement != nil
}
func telegramPrivacyInputRules(_ setting: TelegramPrivacySetting, userHashes: [Int64: Int64], selfID: Int64) -> [Api.InputPrivacyRule]? {
    guard setting.isValid, setting.audience != nil else { return nil }
    func users(_ ids: [Int64]) -> [Api.InputUser]? {
        var result: [Api.InputUser] = []
        for id in ids {
            if id == selfID { result.append(.inputUserSelf) }
            else if let hash = userHashes[id], hash != 0 { result.append(.inputUser(userId: id, accessHash: hash)) }
            else { return nil }
        }
        return result
    }
    var result: [Api.InputPrivacyRule] = []
    for rule in setting.rules {
        switch rule {
        case .everybody: result.append(.inputPrivacyValueAllowAll)
        case .contacts: result.append(.inputPrivacyValueAllowContacts)
        case .nobody: result.append(.inputPrivacyValueDisallowAll)
        case .denyContacts: result.append(.inputPrivacyValueDisallowContacts)
        case .closeFriends: result.append(.inputPrivacyValueAllowCloseFriends)
        case .premium: result.append(.inputPrivacyValueAllowPremium)
        case .bots: result.append(.inputPrivacyValueAllowBots)
        case .denyBots: result.append(.inputPrivacyValueDisallowBots)
        case let .allowChats(ids): result.append(.inputPrivacyValueAllowChatParticipants(chats: ids))
        case let .denyChats(ids): result.append(.inputPrivacyValueDisallowChatParticipants(chats: ids))
        case let .allowUsers(ids): guard let inputs = users(ids) else { return nil }; result.append(.inputPrivacyValueAllowUsers(users: inputs))
        case let .denyUsers(ids): guard let inputs = users(ids) else { return nil }; result.append(.inputPrivacyValueDisallowUsers(users: inputs))
        }
    }
    return result
}
func telegramPrivacyKey(_ kind: TelegramPrivacyKind) -> Api.InputPrivacyKey {
    switch kind {
    case .presence: .inputPrivacyKeyStatusTimestamp
    case .phoneNumber: .inputPrivacyKeyPhoneNumber
    case .phoneDiscovery: .inputPrivacyKeyAddedByPhone
    case .voiceCalls: .inputPrivacyKeyPhoneCall
    case .callP2P: .inputPrivacyKeyPhoneP2P
    case .profilePhoto: .inputPrivacyKeyProfilePhoto
    case .groupInvitations: .inputPrivacyKeyChatInvite
    case .forwards: .inputPrivacyKeyForwards
    case .bio: .inputPrivacyKeyAbout
    case .birthday: .inputPrivacyKeyBirthday
    }
}

public struct TelegramPrivacySnapshot: Equatable, Sendable {
    public let accountID: Int64
    public let settings: [TelegramPrivacyKind: TelegramPrivacySetting]
}
enum TelegramPrivacyError: Error, Equatable, Sendable { case unavailable, changed, failed, uncertain }
@MainActor protocol TelegramPrivacyRequest: AnyObject { func cancel() }
@MainActor protocol TelegramPrivacyProvider: AnyObject {
    var accountID: Int64 { get }
    func load(receive: @escaping @MainActor (Result<TelegramPrivacySnapshot, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest
    func peers(query: String, include: [TelegramPrivacyPeerID], receive: @escaping @MainActor (Result<TelegramPrivacyPeerDirectory, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest
    func apply(_ change: TelegramPrivacyChange, expectedAccountID: Int64, receive: @escaping @MainActor (Result<Void, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest
}
extension TelegramPrivacyProvider {
    func peers(query: String, include: [TelegramPrivacyPeerID], receive: @escaping @MainActor (Result<TelegramPrivacyPeerDirectory, TelegramPrivacyError>) -> Void) -> any TelegramPrivacyRequest {
        receive(.failure(.unavailable)); return UnavailablePrivacyRequest()
    }
}
@MainActor private final class UnavailablePrivacyRequest: TelegramPrivacyRequest { func cancel() {} }
extension TelegramPrivacySnapshot {
    var isValid: Bool {
        accountID != 0 && Set(settings.keys) == Set(TelegramPrivacyKind.allCases)
            && settings.allSatisfy { $0.key == $0.value.kind && $0.value.isValid }
    }
}
@MainActor public final class TelegramPrivacyController: ObservableObject {
    public enum MutationStatus: Equatable { case idle, saving, saved, changed, failed, uncertain }
    @Published public private(set) var snapshot: TelegramPrivacySnapshot?
    @Published public private(set) var status: TelegramSearchStatus = .idle
    @Published public private(set) var mutationStatus: MutationStatus = .idle
    @Published public private(set) var contextID = UUID()
    private var provider: (any TelegramPrivacyProvider)?
    private var read: (any TelegramPrivacyRequest)?, write: (any TelegramPrivacyRequest)?
    private var readID: UUID?, writeID: UUID?
    private var readDeadline: Task<Void, Never>?, writeDeadline: Task<Void, Never>?
    private var uncertainAccounts: Set<Int64> = []
    private var mutationKind: TelegramPrivacyKind?
    public func mutationStatus(for kind: TelegramPrivacyKind) -> MutationStatus {
        if mutationStatus == .saving || mutationStatus == .uncertain { return mutationStatus }
        return mutationKind == kind ? mutationStatus : .idle
    }
    public let peerDirectory = TelegramPrivacyPeerDirectoryController()
    public init() {}
    isolated deinit { read?.cancel(); write?.cancel(); readDeadline?.cancel(); writeDeadline?.cancel() }
    func bind(_ provider: (any TelegramPrivacyProvider)?) { close(); self.provider = provider; peerDirectory.bind(provider) }
    public func open() {
        close()
        if let id = provider?.accountID, uncertainAccounts.contains(id) { mutationStatus = .uncertain }
        load(reconcile: false)
    }
    public func close() {
        peerDirectory.close()
        if mutationStatus == .saving, let id = provider?.accountID { uncertainAccounts.insert(id) }
        contextID = UUID(); readID = nil; writeID = nil
        read?.cancel(); read = nil; write?.cancel(); write = nil
        readDeadline?.cancel(); readDeadline = nil; writeDeadline?.cancel(); writeDeadline = nil
        snapshot = nil; status = .idle; mutationStatus = .idle; mutationKind = nil
    }
    public func refresh() { guard mutationStatus != .saving else { return }; load(reconcile: true) }
    private func load(reconcile: Bool) {
        peerDirectory.close()
        contextID = UUID(); readID = nil; read?.cancel(); read = nil; readDeadline?.cancel(); readDeadline = nil
        guard let provider else { snapshot = nil; status = .failed; return }
        let token = UUID(), context = contextID, accountID = provider.accountID
        readID = token; status = .loading
        readDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.readID == token else { return }
            self.readID = nil; self.read?.cancel(); self.read = nil; self.status = .timedOut
        }
        let request = provider.load { [weak self] result in
            guard let self, self.readID == token, self.contextID == context else { return }
            self.readID = nil; self.readDeadline?.cancel(); self.readDeadline = nil
            self.read?.cancel(); self.read = nil
            switch result {
            case .failure: self.status = .failed
            case let .success(snapshot):
                guard snapshot.accountID == accountID, snapshot.isValid else { self.snapshot = nil; self.status = .failed; return }
                self.snapshot = snapshot; self.status = .ready
                if reconcile, self.mutationStatus == .uncertain {
                    self.uncertainAccounts.remove(accountID); self.mutationStatus = .idle
                }
            }
        }
        if readID == token { read = request } else { request.cancel() }
    }
    @discardableResult public func apply(_ change: TelegramPrivacyChange, contextID: UUID) -> Bool {
        guard self.contextID == contextID, status == .ready, mutationStatus != .saving, mutationStatus != .uncertain,
              let provider, let snapshot, snapshot.accountID == provider.accountID, snapshot.settings[change.expected.kind] == change.expected, change.replacement != nil else { return false }
        let token = UUID(); writeID = token; mutationKind = change.expected.kind; mutationStatus = .saving
        writeDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.writeID == token else { return }; self.timeoutMutation()
        }
        let request = provider.apply(change, expectedAccountID: snapshot.accountID) { [weak self] result in
            guard let self, self.writeID == token, self.contextID == contextID else { return }
            self.writeID = nil; self.writeDeadline?.cancel(); self.writeDeadline = nil; self.write?.cancel(); self.write = nil
            switch result {
            case .success: self.mutationStatus = .saved; self.load(reconcile: false)
            case .failure(.changed): self.mutationStatus = .changed; self.load(reconcile: false)
            case .failure(.uncertain): self.uncertainAccounts.insert(provider.accountID); self.mutationStatus = .uncertain
            case .failure: self.mutationStatus = .failed
            }
        }
        if writeID == token { write = request } else { request.cancel() }
        return true
    }
    func timeoutMutation() {
        guard mutationStatus == .saving, let id = provider?.accountID else { return }
        uncertainAccounts.insert(id); writeID = nil; write?.cancel(); write = nil; writeDeadline?.cancel(); writeDeadline = nil
        mutationStatus = .uncertain
    }
}
