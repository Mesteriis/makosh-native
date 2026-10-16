import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct WhatsAppAvatarScope: Hashable, Sendable {
  public let accountID: UUID
  public let jid: String
  public init(accountID: UUID, jid: String) {
    self.accountID = accountID
    self.jid = jid
  }
}
struct WhatsAppAvatarDescriptor: Codable, Equatable, Sendable {
  let pictureID: String
  let url: URL
}
public struct WhatsAppAvatarImage: Codable, Equatable, Sendable {
  public let encodedPreview: Data
  public let width: Int, height: Int
  public let pictureID: String
  public init(encodedPreview: Data, width: Int, height: Int, pictureID: String) {
    self.encodedPreview = encodedPreview
    self.width = width
    self.height = height
    self.pictureID = pictureID
  }
}
public protocol WhatsAppAvatarFetching: Sendable {
  func fetch(_ url: URL, maximumBytes: Int, timeout: TimeInterval) async throws -> Data
}
actor WhatsAppAvatars {
  private let cache: WhatsAppAvatarCache
  private let http: any WhatsAppAvatarFetching
  private let keyProvider: @Sendable (UUID) async throws -> Data
  private let descriptor: @Sendable (WhatsAppAvatarScope) async throws -> WhatsAppAvatarDescriptor?
  private var generations: [WhatsAppAvatarScope: UInt64] = [:]
  private var pending: [WhatsAppAvatarScope: (UUID, Task<WhatsAppAvatarImage?, Error>)] = [:]
  private var invalidated = Set<WhatsAppAvatarScope>()
  private var accountCutoffs: [UUID: Date] = [:]
  private var active = 0
  private var closed = false
  init(
    root: URL, http: any WhatsAppAvatarFetching,
    keyProvider: @escaping @Sendable (UUID) async throws -> Data,
    descriptor: @escaping @Sendable (WhatsAppAvatarScope) async throws -> WhatsAppAvatarDescriptor?,
    maximumCacheBytes: Int = 64 * 1024 * 1024
  ) {
    cache = .init(root: root, maximumBytes: maximumCacheBytes)
    self.http = http
    self.keyProvider = keyProvider
    self.descriptor = descriptor
  }
  func image(scope: WhatsAppAvatarScope, refresh: Bool = false) async throws -> WhatsAppAvatarImage?
  {
    guard !closed, !scope.jid.isEmpty, scope.jid.utf8.count <= 1024,
      scope.jid.utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
      ["@lid", "@s.whatsapp.net", "@g.us"].contains(where: scope.jid.hasSuffix)
    else { throw WhatsAppFailure.invalid }
    if refresh { invalidate(scope: scope) }
    if let task = pending[scope]?.1 {
      let generation = generations[scope, default: 0]
      let image = try await task.value
      try check(scope, generation)
      return image
    }
    guard pending.count < 512 else { throw WhatsAppFailure.unavailable }
    let generation = generations[scope, default: 0]
    let token = UUID()
    let task = Task { try await self.prepare(scope: scope, generation: generation) }
    pending[scope] = (token, task)
    defer { if pending[scope]?.0 == token { pending[scope] = nil } }
    let value = try await task.value
    try check(scope, generation)
    return value
  }
  func invalidate(scope: WhatsAppAvatarScope) {
    generations[scope, default: 0] &+= 1
    invalidated.insert(scope)
    pending.removeValue(forKey: scope)?.1.cancel()
  }
  func invalidateAccount(_ accountID: UUID) {
    accountCutoffs[accountID] = Date()
    for scope in Set(generations.keys).union(pending.keys) where scope.accountID == accountID {
      invalidate(scope: scope)
    }
  }
  func close() async {
    closed = true
    let tasks = pending.values.map(\.1)
    pending.removeAll()
    for task in tasks { task.cancel() }
    for task in tasks { _ = try? await task.value }
  }
  private func check(_ scope: WhatsAppAvatarScope, _ generation: UInt64) throws {
    try Task.checkCancellation()
    guard !closed, generations[scope, default: 0] == generation else { throw CancellationError() }
  }
  private func prepare(scope: WhatsAppAvatarScope, generation: UInt64) async throws
    -> WhatsAppAvatarImage?
  {
    var raw = try await keyProvider(scope.accountID)
    defer { raw.resetBytes(in: 0..<raw.count) }
    guard raw.count == 32 else { throw WhatsAppFailure.key }
    let key = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: raw),
      salt: Data(scope.accountID.uuidString.utf8),
      info: Data("makosh-whatsapp-avatar-cache-v1".utf8), outputByteCount: 32)
    try check(scope, generation)
    if !invalidated.contains(scope), let record = try cache.load(scope: scope, key: key),
      record.checked >= (accountCutoffs[scope.accountID] ?? .distantPast),
      Date().timeIntervalSince(record.checked) < 600
    {
      return record.image
    }
    while active >= 2 {
      try await Task.sleep(for: .milliseconds(10))
      try check(scope, generation)
    }
    active += 1
    defer { active -= 1 }
    let found = try await descriptor(scope)
    try check(scope, generation)
    let image: WhatsAppAvatarImage?
    if let found {
      guard !found.pictureID.isEmpty, found.pictureID.utf8.count <= 512,
        WhatsAppAvatarHTTP.accepts(found.url)
      else {
        throw WhatsAppFailure.invalid
      }
      let bytes = try await http.fetch(found.url, maximumBytes: 4 * 1024 * 1024, timeout: 20)
      try check(scope, generation)
      image = try Self.decode(bytes, pictureID: found.pictureID)
    } else {
      image = nil
    }
    try check(scope, generation)
    try cache.save(.init(checked: Date(), image: image), scope: scope, key: key)
    invalidated.remove(scope)
    return image
  }
  private static func decode(_ data: Data, pictureID: String) throws -> WhatsAppAvatarImage {
    guard data.count <= 4 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let h = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      w.doubleValue.isFinite, h.doubleValue.isFinite, w.intValue > 0, h.intValue > 0,
      w.intValue <= 16_000_000 / h.intValue,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary),
      image.width <= 512, image.height <= 512
    else { throw WhatsAppFailure.invalid }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      throw WhatsAppFailure.invalid
    }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw WhatsAppFailure.invalid }
    return .init(
      encodedPreview: output as Data, width: image.width, height: image.height, pictureID: pictureID
    )
  }
}

extension WhatsAppRepository {
  func avatarCacheKey(accountID: UUID) throws -> Data {
    try db().avatarCacheKey(accountID: accountID)
  }
}
extension WhatsAppServing {
  public func avatar(accountID: UUID, jid: String, refresh: Bool) async throws
    -> WhatsAppAvatarImage?
  {
    throw WhatsAppFailure.unavailable
  }
}
extension WhatsAppWorker {
  public func avatar(accountID: UUID, jid: String, refresh: Bool = false) async throws
    -> WhatsAppAvatarImage?
  {
    #if DEBUG
      if synthetic, qaRoot != nil, let avatars, let repository,
        try await repository.accounts().contains(where: { $0.id == accountID })
      {
        return try await avatars.image(
          scope: .init(accountID: accountID, jid: jid), refresh: refresh)
      }
    #endif
    guard !synthetic, let avatars, let session = sessions[accountID] else { return nil }
    let revision = revisions[accountID]
    guard try await session.status().linked, revisions[accountID] == revision else {
      throw WhatsAppFailure.closed
    }
    let image = try await avatars.image(
      scope: .init(accountID: accountID, jid: jid), refresh: refresh)
    guard revisions[accountID] == revision, try await session.status().linked,
      revisions[accountID] == revision
    else { throw CancellationError() }
    return image
  }
  func updateAvatars(_ status: WhatsAppConnectionStatus, accountID: UUID) async {
    let generation = revisions[accountID]
    if avatarEpochs[accountID] != status.avatarEpoch {
      await avatars?.invalidateAccount(accountID)
      guard revisions[accountID] == generation else { return }
      avatarEpochs[accountID] = status.avatarEpoch
      avatarRevisions[accountID] = [:]
    }
    for (jid, value) in status.avatarRevisions ?? [:]
    where avatarRevisions[accountID]?[jid] != value {
      await avatars?.invalidate(scope: .init(accountID: accountID, jid: jid))
      guard revisions[accountID] == generation else { return }
    }
    avatarRevisions[accountID] = status.avatarRevisions ?? [:]
  }
}
