import Foundation
import MakoshCore

extension WhatsAppChat {
  public var dossierContact: ImportedContact? {
    guard !group, id.hasSuffix("@lid") || id.hasSuffix("@s.whatsapp.net") else { return nil }
    let user = String(id.split(separator: "@", maxSplits: 1)[0])
    let phone =
      id.hasSuffix("@s.whatsapp.net") && !user.isEmpty && user.allSatisfy(\.isNumber)
      ? ["+" + user] : []
    return .init(externalID: id, displayName: name, phones: phone)
  }
}
