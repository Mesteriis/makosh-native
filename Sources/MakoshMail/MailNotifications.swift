import Foundation
import CryptoKit

public enum MailNotificationScope: Hashable, Codable, Sendable, Identifiable {
    case global, account(String), folder(accountID:String,path:String), sender(accountID:String,address:String)
    public var id: String {
        let parts: [String]
        switch self {
        case .global: parts=["global"]
        case .account(let id): parts=["account",id]
        case .folder(let id,let path): parts=["folder",id,path.uppercased()=="INBOX" ? "INBOX" : path]
        case .sender(let id,let address): parts=["sender",id,address.lowercased()]
        }
        return SHA256.hash(data:Data(parts.joined(separator:"\0").utf8)).map { String(format:"%02x",$0) }.joined()
    }
}
public struct MailNotificationRule: Codable, Equatable, Sendable {
    public var enabled: Bool, previews: Bool, sound: Bool
    public init(enabled:Bool=true,previews:Bool=true,sound:Bool=true) { self.enabled=enabled;self.previews=previews;self.sound=sound }
}
public struct MailNotificationPreferences: Codable, Equatable, Sendable {
    public var global = MailNotificationRule()
    public var showWhileActive = true
    public var overrides: [String:MailNotificationRule] = [:]
    public init() {}
    public func effective(for letter: MailLetter) -> MailNotificationRule {
        let scopes: [MailNotificationScope] = [.account(letter.key.accountID), .folder(accountID:letter.key.accountID,path:letter.key.folder), .sender(accountID:letter.key.accountID,address:letter.sender)]
        return scopes.compactMap { overrides[$0.id] }.reduce(global) { result, rule in
            .init(enabled:result.enabled && rule.enabled,previews:result.previews && rule.previews,sound:result.sound && rule.sound)
        }
    }
    public func effective(for event: MailNotificationEvent) -> MailNotificationRule {
        effective(for:.init(key:event.key,subject:event.subject,senderName:event.senderName,sender:event.sender,recipient:"",date:Date()))
    }
}
public struct MailNotificationEvent: Codable, Equatable, Identifiable, Sendable {
    public let key: MailMessageKey
    public let sender: String, senderName: String, subject: String
    public var id: String { key.id }
    public init(letter:MailLetter) { key=letter.key;sender=letter.sender;senderName=String(letter.senderName.prefix(200));subject=String(letter.subject.prefix(600)) }
}
public struct MailInboxNotificationCheckpoint: Codable, Sendable {
    public let uidValidity: UInt32
    public var maximumUID: UInt32
}
public struct MailNotificationState: Codable, Sendable {
    public var preferences = MailNotificationPreferences()
    public var checkpoints: [String:MailInboxNotificationCheckpoint] = [:]
    public var pending: [MailNotificationEvent] = []
    public var routes: [String: MailNotificationSavedRoute]?
    public init() {}
    mutating func observe(_ letters:[MailLetter],folder:MailFolder,uidValidity:UInt32,synchronizedThroughUID:UInt32? = nil) {
        guard folder.kind == .inbox else { return }
        let previous = checkpoints[folder.id], maximum = max(letters.map(\.key.uid).max() ?? 0, synchronizedThroughUID ?? 0)
        checkpoints[folder.id] = .init(uidValidity:uidValidity,maximumUID:previous?.uidValidity == uidValidity ? max(previous?.maximumUID ?? 0,maximum) : maximum)
        pending.removeAll { $0.key.accountID == folder.accountID && $0.key.folder == folder.path && $0.key.uidValidity != uidValidity }
        guard let previous, previous.uidValidity == uidValidity else { return }
        let existing = Set(pending.map(\.id))
        let incoming = letters.filter { $0.key.uid > previous.maximumUID && !$0.seen && $0.removedFromSource != true && preferences.effective(for:$0).enabled && !existing.contains($0.id) }
        var admitted = Set<String>()
        for letter in incoming.sorted(by:{ $0.key.uid > $1.key.uid }).prefix(5) where admitted.insert(letter.id).inserted {
            pending.append(.init(letter:letter))
        }
        if pending.count > 100 { pending.removeFirst(pending.count-100) }
    }
}
public struct MailNotificationSavedRoute: Codable, Equatable, Sendable {
    public let event: MailNotificationEvent
    public let rule: MailNotificationRule
    public let created: Date
    public var consumed: Bool
    public init(event: MailNotificationEvent, rule: MailNotificationRule, created: Date = Date(), consumed: Bool = false) { self.event = event; self.rule = rule; self.created = created; self.consumed = consumed }
}
public enum MailNotificationAction: String, Sendable { case open, archive, trash }

/// Events and the presentation snapshot are read under one PostgreSQL state lock.
public struct MailNotificationBatch: Sendable {
    public let events: [MailNotificationEvent]
    public let snapshot: MailSnapshot
}
