import Foundation
import MakoshCore
import CPostgres

public enum TelemostQAIsolation {
    public static func validate(configuration: ContactWorkspaceConfiguration, arguments: [String]) throws {
        let flags = ["--telemost-synthetic-preview", "--database-config", "--telemost-qa-exports"]
        guard flags.allSatisfy({ flag in arguments.filter { $0 == flag }.count == 1 }),
              arguments.filter({ $0.hasPrefix("--") }).allSatisfy({ flags.contains($0) }),
              let archive = configuration.archiveSchema else { throw TelemostFailure.invalidConfiguration }
        for flag in flags.dropFirst() {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/"), !arguments[index + 1].utf8.contains(0) else { throw TelemostFailure.invalidConfiguration }
        }
        guard [configuration.schema, archive].allSatisfy({ schema in
            schema.hasPrefix("qa_telemost_") && schema.utf8.count > 12 && schema.utf8.count <= 63 && schema.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
        }) else { throw TelemostFailure.invalidConfiguration }
        guard !configuration.connectionString.utf8.contains(0) else { throw TelemostFailure.invalidConfiguration }
        var error: UnsafeMutablePointer<CChar>?
        guard let parsed = PQconninfoParse(configuration.connectionString, &error) else { if let error { PQfreemem(error) }; throw TelemostFailure.invalidConfiguration }
        defer { PQconninfoFree(parsed); if let error { PQfreemem(error) } }
        var values: [String: String] = [:], index = 0
        while let keyword = parsed[index].keyword {
            if let value = parsed[index].val { values[String(cString: keyword)] = String(cString: value) }; index += 1
        }
        let allowed: Set<String> = ["host", "hostaddr", "port", "dbname", "user", "password", "sslmode", "connect_timeout", "application_name"]
        guard Set(values.keys).isSubset(of: allowed), ["127.0.0.1", "::1", "localhost"].contains(values["host"] ?? ""),
              ["127.0.0.1", "::1"].contains(values["hostaddr"] ?? "") else { throw TelemostFailure.invalidConfiguration }
        if let port = values["port"], Int(port).map({ (1...65535).contains($0) }) != true { throw TelemostFailure.invalidConfiguration }
    }
}
