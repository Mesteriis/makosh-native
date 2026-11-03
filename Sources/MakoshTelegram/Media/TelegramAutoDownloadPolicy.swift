import Foundation
import Combine

public enum TelegramDownloadPeer: String, Codable, CaseIterable, Sendable { case contacts, privateChats, groups, channels }
public enum TelegramDownloadKind: String, CaseIterable, Identifiable, Sendable {
    case photos, videos, files
    public var id: String { rawValue }
}
public struct TelegramDownloadRule: Codable, Equatable, Sendable {
    public var peers: Set<TelegramDownloadPeer> = Set(TelegramDownloadPeer.allCases)
    public var limit: Int64
    public init(limit: Int64) { self.limit = limit }
}
public struct TelegramAutoDownloadPreferences: Codable, Equatable, Sendable {
    public var enabled = false
    public var photos = TelegramDownloadRule(limit: 10 * 1024 * 1024)
    public var videos = TelegramDownloadRule(limit: 10 * 1024 * 1024)
    public var files: TelegramDownloadRule = { var rule = TelegramDownloadRule(limit: 10 * 1024 * 1024); rule.peers = []; return rule }()
    public init() {}
    public subscript(kind: TelegramDownloadKind) -> TelegramDownloadRule {
        get { switch kind { case .photos: photos; case .videos: videos; case .files: files } }
        set { switch kind { case .photos: photos = newValue; case .videos: videos = newValue; case .files: files = newValue } }
    }
    var isValid: Bool { TelegramDownloadKind.allCases.allSatisfy { (1024...Int64(2_147_483_648)).contains(self[$0].limit) } }
    public func allows(_ attachment: TelegramAttachment, peer: TelegramDownloadPeer) -> Bool {
        guard enabled, isValid, attachment.canDownload, !attachment.isSpoiler, attachment.paidMedia == nil,
              let size = attachment.byteCount, size > 0 else { return false }
        let kind: TelegramDownloadKind
        switch attachment.kind {
        case .photo: kind = .photos
        case .file: kind = attachment.playback == .video || attachment.playback == .roundVideo ? .videos : .files
        case .location, .unsupported: return false
        }
        return self[kind].peers.contains(peer) && size <= self[kind].limit
    }
}
@MainActor public final class TelegramAutoDownloadSettings: ObservableObject {
    @Published public private(set) var preferences = TelegramAutoDownloadPreferences()
    @Published public private(set) var contextID = UUID()
    @Published public private(set) var accountID: Int64?
    @Published public private(set) var error: String?
    private let defaults: UserDefaults
    private struct Stored: Codable { let version: Int; let account: Int64; let value: TelegramAutoDownloadPreferences }
    private var observer: NSObjectProtocol?
    private static let changed = Notification.Name("org.makosh.telegram.autoDownloadChanged")
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        observer = NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] event in
            guard let other = event.object as? TelegramAutoDownloadSettings else { return }
            MainActor.assumeIsolated {
                guard let self, other !== self, other.defaults === self.defaults, self.accountID != nil,
                      self.accountID == other.accountID else { return }
                self.contextID = UUID(); self.load()
            }
        }
    }
    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func key(_ account: Int64) -> String { "telegram.autoDownload.v1.\(account)" }
    func bind(accountID: Int64?) { self.accountID = accountID; contextID = UUID(); load() }
    private func load() {
        preferences = .init(); error = nil
        guard let accountID, let object = defaults.object(forKey: key(accountID)) else { return }
        guard let data = object as? Data, data.count <= 65_536, let record = try? JSONDecoder().decode(Stored.self, from: data),
              record.version == 1, record.account == accountID, record.value.isValid else {
            error = "Настройки автозагрузки недоступны. До явного сброса автозагрузка выключена."; return
        }
        preferences = record.value
    }
    @discardableResult public func update(_ value: TelegramAutoDownloadPreferences, contextID: UUID) -> Bool {
        guard error == nil else { return false }; return save(value, contextID: contextID)
    }
    private func save(_ value: TelegramAutoDownloadPreferences, contextID: UUID) -> Bool {
        guard contextID == self.contextID, let accountID, value.isValid,
              let data = try? JSONEncoder().encode(Stored(version: 1, account: accountID, value: value)), data.count <= 65_536 else { return false }
        defaults.set(data, forKey: key(accountID)); preferences = value; error = nil
        NotificationCenter.default.post(name: Self.changed, object: self); return true
    }
    @discardableResult public func reset(contextID: UUID) -> Bool { save(.init(), contextID: contextID) }
}
