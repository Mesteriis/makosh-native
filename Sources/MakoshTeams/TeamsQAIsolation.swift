import Foundation
import MakoshCore
import CPostgres

/// Boundaries for the deliberately public synthetic keys. Ordinary service configuration is unaffected.
public enum TeamsQAIsolation {
    private static func localHost(_ host: String?) -> Bool { ["127.0.0.1", "::1", "localhost"].contains(host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() ?? "") }
    public static func localEndpoint(_ endpoint: String) -> Bool {
        guard let parts = URLComponents(string: endpoint), ["http", "https"].contains(parts.scheme ?? ""), parts.user == nil, parts.password == nil else { return false }
        return localHost(parts.host)
    }
    public static func admitsDatabase(_ configuration: ContactWorkspaceConfiguration) -> Bool {
        guard configuration.schema.hasPrefix("qa_teams_"), configuration.archiveSchema?.hasPrefix("qa_teams_") == true,
              let options = options(configuration.connectionString), localHost(options["host"]) else { return false }
        let allowed = Set(["host", "hostaddr", "port", "dbname", "user", "password", "sslmode", "connect_timeout", "application_name"])
        guard Set(options.keys).isSubset(of: allowed) else { return false }
        if let address = options["hostaddr"] { return ["127.0.0.1", "::1"].contains(address) }
        return true
    }
    private static func options(_ connection: String) -> [String: String]? {
        guard !connection.utf8.contains(0) else { return nil }
        var error: UnsafeMutablePointer<CChar>?
        guard let result = PQconninfoParse(connection, &error) else { if let error { PQfreemem(error) }; return nil }
        defer { PQconninfoFree(result); if let error { PQfreemem(error) } }
        var values: [String: String] = [:], index = 0
        while let keyword = result[index].keyword {
            if let value = result[index].val { values[String(cString: keyword)] = String(cString: value) }
            index += 1
        }
        return values
    }
    public static func hasPinnedLocalDatabase(_ configuration: ContactWorkspaceConfiguration) -> Bool {
        admitsDatabase(configuration) && options(configuration.connectionString)?["hostaddr"] != nil
    }
    static func normalizedDatabase(_ configuration: ContactWorkspaceConfiguration) throws -> ContactWorkspaceConfiguration {
        guard admitsDatabase(configuration), let host = options(configuration.connectionString)?["host"] else { throw TeamsFailure.invalidConfiguration }
        let address = host == "localhost" ? "127.0.0.1" : host
        let connection: String
        if var parts = URLComponents(string: configuration.connectionString), ["postgres", "postgresql"].contains(parts.scheme ?? "") {
            parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "hostaddr" } + [.init(name: "hostaddr", value: address)]
            guard let value = parts.string else { throw TeamsFailure.invalidConfiguration }; connection = value
        } else { connection = configuration.connectionString + " hostaddr=" + address }
        return ContactWorkspaceConfiguration(connectionString: connection, schema: configuration.schema, archiveSchema: configuration.archiveSchema)
    }
    static func permitsFile(_ file: URL, root: URL?) -> Bool {
        guard let root, file.isFileURL, root.isFileURL else { return false }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let candidate = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return candidate.count > base.count && candidate.starts(with: base)
    }
}
