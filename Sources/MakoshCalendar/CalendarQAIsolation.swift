import CPostgres
import Foundation
import MakoshCore

/// The synthetic preview may only run against an explicitly supplied,
/// loopback-only configuration whose schema carries the `qa_calendar_` prefix.
public enum CalendarQAIsolation {
    public static let flag = "--calendar-synthetic-preview"
    public static let schemaPrefix = "qa_calendar_"
    public enum Failure: Error, Equatable { case invalidConfiguration }

    public static func validate(configuration: PersonWorkspaceConfiguration, arguments: [String]) throws {
        let flags = [flag, "--database-config"]
        guard flags.allSatisfy({ flag in arguments.filter { $0 == flag }.count == 1 }),
            arguments.filter({ $0.hasPrefix("--") }).allSatisfy({ flags.contains($0) }),
            let index = arguments.firstIndex(of: "--database-config"), arguments.indices.contains(index + 1),
            arguments[index + 1].hasPrefix("/"), !arguments[index + 1].utf8.contains(0)
        else { throw Failure.invalidConfiguration }
        let schemas = [configuration.schema, configuration.archiveSchema ?? configuration.schema]
        guard
            schemas.allSatisfy({ schema in
                schema.hasPrefix(schemaPrefix) && schema.utf8.count > schemaPrefix.utf8.count && schema.utf8.count <= 63
                    && schema.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
            }), !configuration.connectionString.utf8.contains(0)
        else { throw Failure.invalidConfiguration }
        var error: UnsafeMutablePointer<CChar>?
        guard let parsed = PQconninfoParse(configuration.connectionString, &error) else {
            if let error { PQfreemem(error) }
            throw Failure.invalidConfiguration
        }
        defer {
            PQconninfoFree(parsed)
            if let error { PQfreemem(error) }
        }
        var values: [String: String] = [:]
        var position = 0
        while let keyword = parsed[position].keyword {
            if let value = parsed[position].val { values[String(cString: keyword)] = String(cString: value) }
            position += 1
        }
        let allowed: Set<String> = [
            "host", "hostaddr", "port", "dbname", "user", "password", "sslmode", "connect_timeout", "application_name",
        ]
        guard Set(values.keys).isSubset(of: allowed), ["127.0.0.1", "::1", "localhost"].contains(values["host"] ?? ""),
            ["127.0.0.1", "::1"].contains(values["hostaddr"] ?? "")
        else { throw Failure.invalidConfiguration }
        if let port = values["port"], Int(port).map({ (1...65535).contains($0) }) != true { throw Failure.invalidConfiguration }
    }
}
