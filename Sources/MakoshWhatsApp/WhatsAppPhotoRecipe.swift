import Foundation

public struct WhatsAppPhotoPoint: Codable, Equatable, Sendable {
  public var x: Double, y: Double
  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}
public struct WhatsAppPhotoRect: Codable, Equatable, Sendable {
  public var x: Double, y: Double, width: Double, height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}
public struct WhatsAppPhotoRGBA: Codable, Equatable, Sendable {
  public var r: Double, g: Double, b: Double, a: Double
  public init(r: Double, g: Double, b: Double, a: Double) {
    self.r = r
    self.g = g
    self.b = b
    self.a = a
  }
}
public enum WhatsAppPhotoMark: String, Codable, Sendable { case pen, arrow, rect }
public enum WhatsAppPhotoOperation: Codable, Equatable, Sendable {
  case crop(WhatsAppPhotoRect)
  case rotate90
  case mark(WhatsAppPhotoMark, [WhatsAppPhotoPoint], WhatsAppPhotoRGBA, Double)
}
public struct WhatsAppPhotoRecipe: Codable, Equatable, Sendable {
  public var operations: [WhatsAppPhotoOperation]
  public init(operations: [WhatsAppPhotoOperation] = []) { self.operations = operations }
  public func validate() throws {
    guard operations.count <= 256 else { throw WhatsAppFailure.invalid }
    var count = 0
    func unit(_ values: [Double]) -> Bool {
      values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
    }
    for operation in operations {
      switch operation {
      case .rotate90: break
      case .crop(let r):
        guard unit([r.x, r.y, r.width, r.height]), r.width > 0, r.height > 0,
          r.x + r.width <= 1, r.y + r.height <= 1
        else { throw WhatsAppFailure.invalid }
      case .mark(let kind, let points, let color, let width):
        count += points.count
        guard count <= 32768, !points.isEmpty, kind == .pen || points.count == 2,
          points.allSatisfy({ unit([$0.x, $0.y]) }), unit([color.r, color.g, color.b, color.a]),
          width.isFinite, width > 0, width <= 0.1
        else { throw WhatsAppFailure.invalid }
      }
    }
  }
}
public enum WhatsAppPhotoMode: String, Codable, Sendable { case standard, hd }
public struct WhatsAppPhotoRenderResult: Sendable {
  public let finalJPEG: Data
  public let width: Int, height: Int
}
public struct WhatsAppPhotoPreview: Sendable {
  public let encodedPreview: Data
  public let width: Int, height: Int
}
public struct WhatsAppPhotoDraft: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID, accountID: UUID, sourceID: UUID
  public let chat: String
  public var recipe: WhatsAppPhotoRecipe = .init()
  public var revision: UInt64 = 1
  public var exportedFileID: UUID?, exportedRevision: UInt64?, mode: WhatsAppPhotoMode?
  public var sourceFailed: Bool?
  public var sourceReady = false
  public var width = 0, height = 0
}
