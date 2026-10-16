import CPostgres
import Darwin
import Foundation
import MakoshCore

/// Validate every boundary before constructing stores, providers or device hosts.
public enum WhatsAppQAIsolation {
  public static func permitsNormalLaunch(marker: String?, arguments: [String]) -> Bool {
    marker != "whatsapp" && !arguments.contains("--whatsapp-synthetic-preview")
  }
  public static func root(arguments: [String]) throws -> URL {
    guard let i = arguments.firstIndex(of: "--whatsapp-qa-root"), arguments.indices.contains(i + 1),
      arguments[i + 1].hasPrefix("/")
    else { throw WhatsAppFailure.invalid }
    return URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
  }
  public static func configuration(arguments: [String]) throws -> ContactWorkspaceConfiguration {
    let flags = [
      "--whatsapp-synthetic-preview", "--database-config", "--storage-config", "--whatsapp-qa-root",
    ]
    guard flags.allSatisfy({ flag in arguments.filter { $0 == flag }.count == 1 }),
      arguments.filter({ $0.hasPrefix("--") }).allSatisfy({ flags.contains($0) })
    else { throw WhatsAppFailure.invalid }
    let root = try root(arguments: arguments)
    guard root.path == root.resolvingSymlinksInPath().path,
      let attrs = try? FileManager.default.attributesOfItem(atPath: root.path),
      attrs[.type] as? FileAttributeType == .typeDirectory,
      (attrs[.posixPermissions] as? NSNumber).map({ $0.intValue & 0o077 == 0 }) == true,
      (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
      try readOwned(root.appendingPathComponent(".makosh-whatsapp-qa"))
        == Data("makosh-whatsapp-synthetic-v1".utf8),
      let i = arguments.firstIndex(of: "--database-config"), arguments.indices.contains(i + 1),
      arguments[i + 1] == root.appendingPathComponent("database.json").path
    else { throw WhatsAppFailure.invalid }
    let value = try JSONDecoder().decode(
      ContactWorkspaceConfiguration.self,
      from: readOwned(root.appendingPathComponent("database.json")))
    try validate(configuration: value, arguments: arguments)
    return value
  }
  public static func validate(configuration: ContactWorkspaceConfiguration, arguments: [String])
    throws
  {
    let flags = [
      "--whatsapp-synthetic-preview", "--database-config", "--storage-config", "--whatsapp-qa-root",
    ]
    guard flags.allSatisfy({ flag in arguments.filter { $0 == flag }.count == 1 }),
      arguments.filter({ $0.hasPrefix("--") }).allSatisfy({ flags.contains($0) }),
      let archive = configuration.archiveSchema, configuration.schema != archive
    else { throw WhatsAppFailure.invalid }
    for schema in [configuration.schema, archive] {
      guard schema.hasPrefix("qa_whatsapp_"), schema.utf8.count > 12, schema.utf8.count <= 63,
        schema.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 })
      else { throw WhatsAppFailure.invalid }
    }
    let root = try root(arguments: arguments)
    guard root.path == root.resolvingSymlinksInPath().path else { throw WhatsAppFailure.invalid }
    let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw WhatsAppFailure.invalid }
    defer { Darwin.close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
      throw WhatsAppFailure.invalid
    }
    guard
      try readOwned(root.appendingPathComponent(".makosh-whatsapp-qa"))
        == Data("makosh-whatsapp-synthetic-v1".utf8)
    else { throw WhatsAppFailure.invalid }
    var paths: [String: URL] = [:]
    for flag in ["--database-config", "--storage-config"] {
      guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1),
        arguments[i + 1].hasPrefix("/"), !arguments[i + 1].utf8.contains(0)
      else { throw WhatsAppFailure.invalid }
      let path = URL(fileURLWithPath: arguments[i + 1]).standardizedFileURL
      guard path.deletingLastPathComponent() == root,
        path.path == path.resolvingSymlinksInPath().path
      else { throw WhatsAppFailure.invalid }
      paths[flag] = path
    }
    guard let dbFile = paths["--database-config"], let storageFile = paths["--storage-config"]
    else { throw WhatsAppFailure.invalid }
    let saved = try JSONDecoder().decode(
      ContactWorkspaceConfiguration.self, from: readOwned(dbFile))
    guard saved.connectionString == configuration.connectionString,
      saved.schema == configuration.schema, saved.archiveSchema == archive,
      !configuration.connectionString.utf8.contains(0)
    else { throw WhatsAppFailure.invalid }
    var error: UnsafeMutablePointer<CChar>?
    guard let parsed = PQconninfoParse(configuration.connectionString, &error) else {
      if let error { PQfreemem(error) }
      throw WhatsAppFailure.invalid
    }
    defer {
      PQconninfoFree(parsed)
      if let error { PQfreemem(error) }
    }
    var values: [String: String] = [:]
    var index = 0
    while let key = parsed[index].keyword {
      if let value = parsed[index].val { values[String(cString: key)] = String(cString: value) }
      index += 1
    }
    let allowed: Set<String> = [
      "host", "hostaddr", "port", "dbname", "user", "password", "sslmode", "connect_timeout",
      "application_name",
    ]
    guard Set(values.keys).isSubset(of: allowed),
      ["127.0.0.1", "::1", "localhost"].contains(values["host"] ?? ""),
      ["127.0.0.1", "::1"].contains(values["hostaddr"] ?? "")
    else { throw WhatsAppFailure.invalid }
    if let port = values["port"], Int(port).map({ (1...65535).contains($0) }) != true {
      throw WhatsAppFailure.invalid
    }
    let storage = try JSONDecoder().decode(
      S3ObjectStoreConfiguration.self, from: readOwned(storageFile))
    guard let host = URLComponents(string: storage.endpoint)?.host,
      ["127.0.0.1", "::1", "[::1]"].contains(host)
    else { throw WhatsAppFailure.invalid }
  }
  static func readOwned(_ url: URL) throws -> Data {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw WhatsAppFailure.invalid }
    defer { Darwin.close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFREG,
      st.st_mode & 0o077 == 0, st.st_size > 0, st.st_size <= 16384
    else { throw WhatsAppFailure.invalid }
    var data = Data(count: Int(st.st_size))
    let size = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    guard size == data.count else { throw WhatsAppFailure.invalid }
    return data
  }
}
