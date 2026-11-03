import Foundation
import TelegramCore
import MtProtoKit
import Darwin

public enum TelegramProxyKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case socks5, mtproto
    public var id: String { rawValue }
}
public struct TelegramProxyDraft: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var kind = TelegramProxyKind.socks5
    public var host = "", port = "", username = "", password = "", secret = ""
    public init() {}
    public var description: String { "TelegramProxyDraft(redacted)" }
    public var debugDescription: String { description }
}
enum TelegramProxyError: Error { case invalid, unavailable, changed }
private nonisolated func proxyHost(_ value: String) -> String? {
    var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    guard !host.isEmpty, host.utf8.count <= 253,
          !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
    var v4 = in_addr(), v6 = in6_addr()
    if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 || host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return host.lowercased() }
    guard !host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return nil }
    let domain = host.hasSuffix(".") ? String(host.dropLast()) : host
    let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy({ label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
    }) else { return nil }
    return host.lowercased()
}
private nonisolated func proxyCredential(_ value: String?) -> Bool {
    value.map { !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains("\u{0000}") } ?? true
}
struct TelegramProxyServer: Codable, Equatable, Sendable, Identifiable, CustomStringConvertible, CustomDebugStringConvertible {
    enum Connection: Codable, Equatable, Sendable { case socks5(username: String?, password: String?), mtproto(Data) }
    let id: UUID, host: String, port: UInt16, connection: Connection
    init(id: UUID = UUID(), draft: TelegramProxyDraft) throws {
        let rawPort = draft.port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = proxyHost(draft.host), !rawPort.isEmpty, rawPort.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(rawPort), port > 0 else { throw TelegramProxyError.invalid }
        let connection: Connection
        switch draft.kind {
        case .socks5:
            let username = draft.username.isEmpty ? nil : draft.username, password = draft.password.isEmpty ? nil : draft.password
            guard proxyCredential(username), proxyCredential(password), password == nil || username != nil else { throw TelegramProxyError.invalid }
            connection = .socks5(username: username, password: password)
        case .mtproto:
            let input = draft.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty, input.utf8.count <= 1024, !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  let parsed = MTProxySecret.parse(input) else { throw TelegramProxyError.invalid }
            connection = .mtproto(parsed.serialize())
        }
        self.id = id; self.host = host; self.port = port; self.connection = connection
        guard isValid else { throw TelegramProxyError.invalid }
    }
    var kind: TelegramProxyKind { if case .mtproto = connection { return .mtproto }; return .socks5 }
    var isValid: Bool {
        guard port > 0, proxyHost(host) == host else { return false }
        switch connection {
        case let .socks5(username, password): return proxyCredential(username) && proxyCredential(password) && (password == nil || username != nil)
        case let .mtproto(data): return data.count <= 512 && MTProxySecret.parseData(data)?.serialize() == data
        }
    }
    var native: ProxyServerSettings {
        let value: ProxyServerConnection
        switch connection {
        case let .socks5(username, password): value = .socks5(username: username, password: password)
        case let .mtproto(secret): value = .mtp(secret: secret)
        }
        return ProxyServerSettings(host: host, port: Int32(port), connection: value)
    }
    var draft: TelegramProxyDraft {
        var value = TelegramProxyDraft(); value.kind = kind; value.host = host; value.port = String(port)
        switch connection {
        case let .socks5(username, password): value.username = username ?? ""; value.password = password ?? ""
        case let .mtproto(secret): value.secret = MTProxySecret.parseData(secret)?.serializeToString() ?? ""
        }
        return value
    }
    var description: String { "Proxy credentials redacted" }
    var debugDescription: String { description }
}
struct TelegramProxyConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var servers: [TelegramProxyServer] = []
    var selected: UUID?
    init() {}
    var isValid: Bool {
        servers.count <= 32 && servers.allSatisfy(\.isValid) && Set(servers.map(\.id)).count == servers.count &&
            (selected.map { id in servers.contains { $0.id == id } } ?? !enabled)
    }
    func native() throws -> ProxySettings {
        guard isValid else { throw TelegramProxyError.invalid }
        let active = enabled ? servers.first { $0.id == selected }?.native : nil
        guard !enabled || active != nil else { throw TelegramProxyError.invalid }
        return ProxySettings(enabled: enabled, servers: active.map { [$0] } ?? [], activeServer: active, useForCalls: false)
    }
}
