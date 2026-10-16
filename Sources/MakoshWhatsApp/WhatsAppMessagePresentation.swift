import Foundation
import MakoshCore

public struct WhatsAppPollOptionPresentation: Identifiable, Equatable, Sendable {
  public var id: Int
  public var label: String
}
public struct WhatsAppMessagePresentation: Equatable, Sendable {
  public var contact: WhatsAppContactPresentation?
  public var bodyText: String?
  public var pollOptions: [WhatsAppPollOptionPresentation]
  public static func make(_ message: WhatsAppMessage) -> Self {
    let repeatedQuestion =
      message.kind == "poll"
      && message.details?.pollName.map {
        $0.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
          == message.text.precomposedStringWithCanonicalMapping.trimmingCharacters(
            in: .whitespacesAndNewlines)
      } == true
    return .init(
      contact: message.kind == "contact"
        ? WhatsAppContactParser.parse(
          message.details?.contactVcard ?? "",
          fallbackName: message.details?.contactName ?? "Контакт") : nil,
      bodyText: message.text.isEmpty || repeatedQuestion ? nil : message.text,
      pollOptions: (message.details?.pollOptions ?? []).enumerated().map {
        .init(id: $0.offset, label: $0.element)
      })
  }
  @concurrent public static func load(_ message: WhatsAppMessage) async throws -> Self {
    try await BackgroundWork.run { make(message) }
  }
}
public enum WhatsAppChatListProjection {
  public static func visible(_ chats: [WhatsAppChat]) -> [WhatsAppChat] {
    chats.filter { $0.id != "status@broadcast" }
  }
}
