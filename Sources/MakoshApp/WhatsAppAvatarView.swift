import AppKit
import ImageIO
import MakoshCore
import MakoshWhatsApp
import SwiftUI

@MainActor final class WhatsAppAvatarWindowCache {
  private struct Key: Hashable {
    let scope: WhatsAppAvatarScope
    let picture: String
  }
  private struct Entry {
    let image: NSImage
    let cost: Int
    var used: UInt64
  }
  private let maximumCost: Int
  private var values: [Key: Entry] = [:]
  private var clock: UInt64 = 0
  private(set) var cost = 0
  var count: Int { values.count }
  init(maximumCost: Int = 8 * 1024 * 1024) {
    self.maximumCost = max(1, min(maximumCost, 8 * 1024 * 1024))
  }
  func image(_ value: WhatsAppAvatarImage, scope: WhatsAppAvatarScope) async throws -> NSImage {
    let key = Key(scope: scope, picture: value.pictureID)
    clock &+= 1
    if var hit = values[key] {
      hit.used = clock
      values[key] = hit
      return hit.image
    }
    let cg = try await BackgroundWork.run {
      guard value.encodedPreview.count <= 4 * 1024 * 1024,
        (1...512).contains(value.width), (1...512).contains(value.height),
        let source = CGImageSourceCreateWithData(value.encodedPreview as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512, kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary),
        image.width == value.width, image.height == value.height
      else { throw WhatsAppFailure.invalid }
      return image
    }
    try Task.checkCancellation()
    let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    let bytes = cg.bytesPerRow * cg.height
    if bytes <= maximumCost {
      if let old = values.removeValue(forKey: key) { cost -= old.cost }
      while cost + bytes > maximumCost,
        let oldest = values.min(by: { $0.value.used < $1.value.used })
      {
        values[oldest.key] = nil
        cost -= oldest.value.cost
      }
      clock &+= 1
      values[key] = .init(image: image, cost: bytes, used: clock)
      cost += bytes
    }
    return image
  }
  func invalidate(_ scope: WhatsAppAvatarScope) {
    for key in values.keys.filter({ $0.scope == scope }) {
      if let old = values.removeValue(forKey: key) { cost -= old.cost }
    }
  }
}
@MainActor final class WhatsAppAvatarModel: ObservableObject {
  @Published private(set) var image: NSImage?
  @Published private(set) var unavailable = false
  private(set) var scope: WhatsAppAvatarScope?
  private let worker: any WhatsAppServing
  private let cache: WhatsAppAvatarWindowCache
  private var generation: UInt64 = 0
  init(worker: any WhatsAppServing, cache: WhatsAppAvatarWindowCache) {
    self.worker = worker
    self.cache = cache
  }
  func load(scope: WhatsAppAvatarScope, refresh: Bool = false) async {
    generation &+= 1
    let token = generation
    self.scope = scope
    image = nil
    unavailable = false
    if refresh { cache.invalidate(scope) }
    do {
      let value = try await worker.avatar(
        accountID: scope.accountID, jid: scope.jid, refresh: refresh)
      guard generation == token, self.scope == scope, !Task.isCancelled else { return }
      guard let value else { return }
      let decoded = try await cache.image(value, scope: scope)
      guard generation == token, self.scope == scope, !Task.isCancelled else { return }
      image = decoded
    } catch {
      if generation == token, !Task.isCancelled, !(error is CancellationError) {
        unavailable = true
      }
    }
  }
}

struct WhatsAppAvatarView: View {
  private struct Request: Equatable {
    let scope: WhatsAppAvatarScope
    let revision: UInt64, epoch: UInt64, manual: UInt64
  }
  let name: String, group: Bool
  let scope: WhatsAppAvatarScope?
  let revision: UInt64, epoch: UInt64
  @State private var manual: UInt64 = 0
  @State private var loaded: Request?
  @StateObject private var model: WhatsAppAvatarModel
  init(
    name: String, group: Bool, scope: WhatsAppAvatarScope?, revision: UInt64 = 0, epoch: UInt64 = 0,
    worker: any WhatsAppServing, cache: WhatsAppAvatarWindowCache
  ) {
    self.name = name
    self.group = group
    self.scope = scope
    self.revision = revision
    self.epoch = epoch
    _model = StateObject(wrappedValue: .init(worker: worker, cache: cache))
  }
  private var request: Request? {
    scope.map { .init(scope: $0, revision: revision, epoch: epoch, manual: manual) }
  }
  var body: some View {
    Group {
      if loaded == request, model.scope == scope, let image = model.image {
        Image(nsImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(
          Circle())
      } else {
        WhatsAppAvatar(name: name, group: group)
      }
    }
    .help(
      model.unavailable ? "Фотография недоступна. Можно обновить через контекстное меню." : name
    )
    .contextMenu { Button("Обновить фотографию") { manual &+= 1 }.disabled(scope == nil) }
    .task(id: request) {
      guard let request else { return }
      await model.load(scope: request.scope, refresh: request.manual > 0)
      guard !Task.isCancelled else { return }
      loaded = request
    }
  }
}
