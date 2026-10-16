import XCTest

@testable import MakoshWhatsApp

final class WhatsAppPhotoRecipeTests: XCTestCase {
  func testInvalidFiniteCropPointAndOperationBounds() throws {
    let valid = WhatsAppPhotoOperation.mark(
      .pen, [.init(x: 0, y: 0), .init(x: 1, y: 1)], .init(r: 1, g: 0, b: 0, a: 1), 0.01)
    try WhatsAppPhotoRecipe(operations: [
      valid, .rotate90, .crop(.init(x: 0, y: 0, width: 1, height: 1)),
    ]).validate()
    for rect in [
      WhatsAppPhotoRect(x: .nan, y: 0, width: 1, height: 1),
      .init(x: 0.5, y: 0, width: 1, height: 1), .init(x: 0, y: 0, width: 0, height: 1),
    ] {
      XCTAssertThrowsError(try WhatsAppPhotoRecipe(operations: [.crop(rect)]).validate())
    }
    XCTAssertThrowsError(
      try WhatsAppPhotoRecipe(operations: Array(repeating: .rotate90, count: 257)).validate())
    XCTAssertThrowsError(
      try WhatsAppPhotoRecipe(operations: [
        .mark(
          .pen, Array(repeating: .init(x: 0, y: 0), count: 32769), .init(r: 1, g: 1, b: 1, a: 1),
          0.01)
      ]).validate())
    XCTAssertThrowsError(
      try WhatsAppPhotoRecipe(operations: [
        .mark(
          .arrow, [.init(x: .infinity, y: 0), .init(x: 1, y: 1)], .init(r: 1, g: 0, b: 0, a: 1),
          0.01)
      ]).validate())
    XCTAssertThrowsError(try WhatsAppPhotoRenderer.validateDimensions(width: 8000, height: 6000))
  }
}
