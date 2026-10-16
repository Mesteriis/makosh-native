import CryptoKit
import Darwin
import Foundation

/// Owned only by the avatar actor. Neither file payloads nor cache records use
/// PostgreSQL or S3; this disposable cache has no access to retained messages.
struct WhatsAppAvatarCache {
  struct Record: Codable {
    let checked: Date
    let image: WhatsAppAvatarImage?
  }
  let root: URL
  let maximumBytes: Int
  func load(scope: WhatsAppAvatarScope, key: SymmetricKey) throws -> Record? {
    let directory = try directory(scope.accountID, create: false)
    let url = file(scope: scope, key: key, directory: directory)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try withLock(directory: directory) { try read(url: url, scope: scope, key: key) }
  }
  private func read(url: URL, scope: WhatsAppAvatarScope, key: SymmetricKey) throws -> Record {
    let properties = try url.resourceValues(forKeys: [
      .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey,
    ])
    guard properties.isSymbolicLink == false, properties.isRegularFile == true,
      let size = properties.fileSize, size <= 4 * 1024 * 1024
    else { throw WhatsAppFailure.storage }
    let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
    let clear = try AES.GCM.open(box, using: key, authenticating: binding(scope))
    let record = try JSONDecoder().decode(Record.self, from: clear)
    if let image = record.image {
      guard (1...512).contains(image.width), (1...512).contains(image.height),
        image.encodedPreview.count <= 4 * 1024 * 1024
      else { throw WhatsAppFailure.storage }
    }
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    return record
  }
  func save(_ record: Record, scope: WhatsAppAvatarScope, key: SymmetricKey) throws {
    let directory = try directory(scope.accountID, create: true)
    try withLock(directory: directory) {
      try write(record, scope: scope, key: key, directory: directory)
    }
  }
  private func write(
    _ record: Record, scope: WhatsAppAvatarScope, key: SymmetricKey, directory: URL
  ) throws {
    let url = file(scope: scope, key: key, directory: directory)
    if FileManager.default.fileExists(atPath: url.path),
      try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    {
      throw WhatsAppFailure.storage
    }
    let clear = try JSONEncoder().encode(record)
    guard let data = try AES.GCM.seal(clear, using: key, authenticating: binding(scope)).combined
    else {
      throw WhatsAppFailure.storage
    }
    guard maximumBytes > 0, maximumBytes <= 64 * 1024 * 1024, data.count <= maximumBytes else {
      throw WhatsAppFailure.invalid
    }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [
        .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey,
      ])
    var rows: [(URL, Int, Date)] = []
    for file in files {
      let props = try file.resourceValues(forKeys: [
        .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey,
      ])
      guard props.isSymbolicLink == false, props.isRegularFile == true else {
        throw WhatsAppFailure.storage
      }
      if file.lastPathComponent == ".lock" { continue }
      let stem = file.deletingPathExtension().lastPathComponent
      guard file.pathExtension == "bin", stem.utf8.count == 64,
        stem.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw WhatsAppFailure.storage }
      rows.append((file, props.fileSize ?? 0, props.contentModificationDate ?? .distantPast))
    }
    var total = rows.filter { $0.0 != url }.reduce(data.count) { $0 + $1.1 }
    for (file, size, _) in rows.sorted(by: { $0.2 < $1.2 })
    where file != url && total > maximumBytes {
      try FileManager.default.removeItem(at: file)
      total -= size
    }
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
  private func withLock<Value>(directory: URL, _ body: () throws -> Value) throws -> Value {
    let fd = Darwin.open(
      directory.appendingPathComponent(".lock").path,
      O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK, 0o600)
    guard fd >= 0 else { throw WhatsAppFailure.unavailable }
    defer { Darwin.close(fd) }
    return try body()
  }
  private func directory(_ account: UUID, create: Bool) throws -> URL {
    let directory = root.appendingPathComponent(account.uuidString.lowercased(), isDirectory: true)
    for path in [root, directory] {
      if FileManager.default.fileExists(atPath: path.path) {
        let props = try path.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard props.isSymbolicLink == false, props.isDirectory == true else {
          throw WhatsAppFailure.storage
        }
      } else if create {
        try FileManager.default.createDirectory(
          at: path, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      }
    }
    return directory
  }
  private func binding(_ scope: WhatsAppAvatarScope) -> Data {
    Data((scope.accountID.uuidString + "\0" + scope.jid).utf8)
  }
  private func file(scope: WhatsAppAvatarScope, key: SymmetricKey, directory: URL) -> URL {
    let name = HMAC<SHA256>.authenticationCode(for: binding(scope), using: key).map {
      String(format: "%02x", $0)
    }.joined()
    return directory.appendingPathComponent(name + ".bin")
  }
}
