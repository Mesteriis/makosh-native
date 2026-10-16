import Foundation
import CryptoKit
import MakoshCore

public enum MailConnectionSecurity: String, Codable, CaseIterable, Sendable { case tls, startTLS }
public struct MailAccount: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var email: String
    public var imapHost: String
    public var imapPort: Int
    public var imapSecurity: MailConnectionSecurity
    public var imapUsername: String
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpSecurity: MailConnectionSecurity
    public var smtpUsername: String
    public init(id: String = UUID().uuidString, displayName: String, email: String, imapHost: String,
                imapPort: Int = 993, imapSecurity: MailConnectionSecurity = .tls, imapUsername: String,
                smtpHost: String, smtpPort: Int = 465, smtpSecurity: MailConnectionSecurity = .tls, smtpUsername: String) {
        self.id=id; self.displayName=displayName; self.email=email; self.imapHost=imapHost
        self.imapPort=imapPort; self.imapSecurity=imapSecurity; self.imapUsername=imapUsername
        self.smtpHost=smtpHost; self.smtpPort=smtpPort; self.smtpSecurity=smtpSecurity; self.smtpUsername=smtpUsername
    }
    public func validate() throws {
        guard UUID(uuidString:id) != nil, MailAddress.isValid(email),
              [imapHost,smtpHost].allSatisfy({ !$0.isEmpty && $0.utf8.count<=253 && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-:".unicodeScalars.contains($0) } }),
              [imapPort,smtpPort].allSatisfy({ (1...65535).contains($0) }),
              [displayName,imapUsername,smtpUsername].allSatisfy({ !$0.isEmpty && $0.utf8.count<=512 && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }) else { throw MailFailure.invalidInput }
    }
    public func sameSource(as other: MailAccount) -> Bool {
        email == other.email && imapHost == other.imapHost && imapPort == other.imapPort && imapSecurity == other.imapSecurity && imapUsername == other.imapUsername && smtpHost == other.smtpHost && smtpPort == other.smtpPort && smtpSecurity == other.smtpSecurity && smtpUsername == other.smtpUsername
    }
    var transport: MailAccountConfig {
        .init(id:id,displayName:displayName,email:email,imapHost:imapHost,imapPort:imapPort,
              imapSecurity:imapSecurity == .tls ? .tls : .startTLS,imapUsername:imapUsername,
              smtpHost:smtpHost,smtpPort:smtpPort,smtpSecurity:smtpSecurity == .tls ? .tls : .startTLS,smtpUsername:smtpUsername)
    }
}
public enum MailAddress {
    public static func isValid(_ value: String) -> Bool {
        let pieces=value.split(separator:"@",omittingEmptySubsequences:false)
        return pieces.count==2 && pieces.allSatisfy({ !$0.isEmpty }) && value.utf8.count<=254
            && value.unicodeScalars.allSatisfy { $0.isASCII && $0.value>32 && $0.value<127 && !"<>(),:;\\\"".unicodeScalars.contains($0) }
    }
    public static func recipients(_ value: String) throws -> [String] {
        let values=value.split(separator:",").map { $0.trimmingCharacters(in:.whitespaces) }
        guard !values.isEmpty,values.count<=100,values.allSatisfy(isValid) else { throw MailFailure.invalidInput }
        return values
    }
}
public struct MailMessageKey: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let accountID: String
    public let folder: String
    public let uidValidity: UInt32
    public let uid: UInt32
    public init(accountID: String, folder: String, uidValidity: UInt32, uid: UInt32) {
        self.accountID=accountID; self.folder=folder.uppercased()=="INBOX" ? "INBOX" : folder
        self.uidValidity=uidValidity; self.uid=uid
    }
    public var id: String { SHA256.hash(data: Data("\(accountID)\u{0}\(folder)\u{0}\(uidValidity)\u{0}\(uid)".utf8)).map { String(format:"%02x",$0) }.joined() }
    public var archiveIdentity: MessageArchiveIdentity {
        .init(service:"mail",accountID:accountID,conversationID:Data(folder.utf8).base64EncodedString(),messageID:"\(uidValidity):\(uid)")
    }
}
public enum MailFolderKind: String, Codable, Sendable { case inbox, sent, drafts, trash, junk, archive, other
    public var title: String { switch self { case .inbox:"Входящие";case .sent:"Отправленные";case .drafts:"Черновики";case .trash:"Корзина";case .junk:"Спам";case .archive:"Архив";case .other:"Папка" } }
    public var symbol: String { switch self { case .inbox:"tray";case .sent:"paperplane";case .drafts:"square.and.pencil";case .trash:"trash";case .junk:"exclamationmark.shield";case .archive:"archivebox";case .other:"folder" } }
}
public struct MailFolder: Codable, Equatable, Identifiable, Sendable {
    public let accountID: String; public let path: String; public let kind: MailFolderKind; public var uidValidity: UInt32?; public var displayName: String?
    public var id: String { accountID+"|"+Data(path.utf8).base64EncodedString() }
    public var title: String { kind == .other ? (displayName ?? path) : kind.title }
    public init(accountID: String,path: String,kind: MailFolderKind, uidValidity: UInt32? = nil, displayName: String? = nil) { self.accountID=accountID;self.path=path.uppercased() == "INBOX" ? "INBOX" : path;self.kind=kind;self.uidValidity=uidValidity;self.displayName=displayName }
}
public struct MailAttachment: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var filename: String; public var mimeType: String; public var byteCount: Int
    public init(id: String,filename: String,mimeType: String,byteCount: Int) { self.id=id;self.filename=filename;self.mimeType=mimeType;self.byteCount=byteCount }
}
public struct MailLetter: Codable, Equatable, Identifiable, Sendable {
    public var key: MailMessageKey; public var subject: String; public var senderName: String; public var sender: String
    public var recipient: String; public var date: Date; public var seen: Bool; public var flagged: Bool
    public var cacheSequence: Int64?
    public var isBodyPreview: Bool?
    public var cc: String?; public var bcc: String?
    public var removedFromSource: Bool?
    public var messageID: String; public var text: String?; public var html: String?; public var attachments: [MailAttachment]
    public var id: String { key.id }
    public init(key: MailMessageKey,subject: String,senderName: String,sender: String,recipient: String,date: Date,
                seen: Bool=false,flagged: Bool=false,messageID: String="",text: String?=nil,html: String?=nil,attachments: [MailAttachment]=[]) {
        self.key=key;self.subject=subject;self.senderName=senderName;self.sender=sender;self.recipient=recipient
        self.date=date;self.seen=seen;self.flagged=flagged;self.messageID=messageID;self.text=text;self.html=html;self.attachments=attachments
    }
    public var dossierContact: ImportedContact { .init(externalID:sender.lowercased(),displayName:senderName.isEmpty ? sender : senderName,emails:[sender]) }
}
public struct MailDraftAttachment: Codable, Equatable, Identifiable, Sendable {
    public let record: ArchiveFileRecord
    public var id: UUID { record.id }
    public var filename: String { record.attachment.name }
    public init(record: ArchiveFileRecord) { self.record = record }
}
public struct MailDraft: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID; public var accountID: String; public var to: String; public var cc: String; public var bcc: String
    public var subject: String; public var body: String; public var replyMessageID: String?
    public var sourceFolder: String; public var files: [MailDraftAttachment]
    public var bodyHTML: String?; public var bodyRTF: Data?
    public var remoteSave: MailDraftRemoteSave?
    public var insertedSignature: String?
    public init(id: UUID = UUID(),accountID: String,to: String="",cc: String="",bcc: String="",subject: String="",body: String="",replyMessageID: String?=nil,sourceFolder: String="INBOX",files: [MailDraftAttachment]=[],bodyHTML: String?=nil,bodyRTF: Data?=nil) {
        self.id=id;self.accountID=accountID;self.to=to;self.cc=cc;self.bcc=bcc;self.subject=subject;self.body=body;self.replyMessageID=replyMessageID;self.sourceFolder=sourceFolder;self.files=files;self.bodyHTML=bodyHTML;self.bodyRTF=bodyRTF
    }
    public func validateForSaving() throws {
        if !to.isEmpty { _ = try MailAddress.recipients(to) }
        if !cc.isEmpty { _ = try MailAddress.recipients(cc) }; if !bcc.isEmpty { _ = try MailAddress.recipients(bcc) }
        guard subject.utf8.count <= 998, !subject.contains(where: { $0.isNewline || $0 == "\0" }), body.utf8.count <= 8*1024*1024, (bodyHTML?.utf8.count ?? 0) <= 8*1024*1024, (bodyRTF?.count ?? 0) <= 8*1024*1024 else { throw MailFailure.invalidInput }
    }
    public func validate() throws {
        try validateForSaving()
        _ = try MailAddress.recipients(to)
        if !cc.isEmpty { _ = try MailAddress.recipients(cc) };if !bcc.isEmpty { _ = try MailAddress.recipients(bcc) }
        guard subject.utf8.count<=998,!subject.contains(where: { $0.isNewline || $0 == "\0" }),body.utf8.count<=8*1024*1024,(bodyHTML?.utf8.count ?? 0)<=8*1024*1024,(bodyRTF?.count ?? 0)<=8*1024*1024 else { throw MailFailure.invalidInput }
    }
}
public struct MailDraftRemoteSave: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case appending, saved, unknown, notDispatched, userConfirmedSaved, userConfirmedMissing }
    public var digest: String
    public var attempt: UUID? = UUID()
    public var state: State
    public init(digest: String, state: State) { self.digest = digest; self.state = state }
    public var unresolved: Bool { state == .appending || state == .unknown }
}
public enum MailSubmissionState: String, Codable, Sendable { case submitting, accepted, unknown, rejected, userConfirmedSent, userConfirmedNotSent }
public struct MailSubmission: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID; public let draftID: UUID; public let accountID: String; public var state: MailSubmissionState; public let date: Date
    public var rawMessage: ArchiveFileRecord?
    public var sentCopySaved: Bool
    public init(id: UUID=UUID(),draftID: UUID,accountID: String,state: MailSubmissionState,date: Date=Date(),sentCopySaved: Bool=false) {
        self.id=id;self.draftID=draftID;self.accountID=accountID;self.state=state;self.date=date;self.sentCopySaved=sentCopySaved
    }
}
public enum MailFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidInput, storage, keychain, offline, staleFolder, tooLarge, unknownSubmission, unknownDraftSave, serverRejected, busy
    public var errorDescription: String? { switch self {
    case .invalidInput:"Проверьте адреса и настройки подключения. Заголовки не могут содержать переносы строк."
    case .storage:"Почтовое хранилище PostgreSQL недоступно. Повтор отправки запрещён до проверки состояния."
    case .keychain:"Не удалось прочитать или сохранить ключ почты в Связке ключей."
    case .offline:"Аккаунт не подключён. Сохранённые письма доступны локально."
    case .staleFolder:"Папка на сервере изменилась. Обновите список писем. Сохранённые версии остаются в архиве."
    case .tooLarge:"Письмо превышает лимит загрузки 32 МБ."
    case .unknownSubmission:"Результат отправки неизвестен. Проверьте письмо у получателя; автоматический повтор отключён."
    case .unknownDraftSave:"Черновик сохранён локально. Исход сохранения на сервере неизвестен. Проверьте папку Черновики; повтор APPEND заблокирован."
    case .serverRejected:"Почтовый сервер отклонил операцию."
    case .busy:"Дождитесь завершения текущей почтовой операции."
    } }
}

public enum MailRefreshEvent: Sendable { case updated(folderID: String), offline(folderID: String) }
