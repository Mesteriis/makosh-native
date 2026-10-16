import Foundation

public struct WhatsAppContactField: Equatable, Identifiable, Sendable {
  public enum Kind: String, Sendable { case phone, email, organization }
  public var kind: Kind
  public var label: String
  public var value: String
  public var stableID: Int
  public var id: Int { stableID }
}
public struct WhatsAppContactPresentation: Equatable, Sendable {
  public var name: String
  public var fields: [WhatsAppContactField]
  public var isMalformed: Bool
  public var sourcePreview: String
  public var sourceTruncated: Bool
}

/// A display-only parser. The received vCard stays in the source archive;
/// unknown properties, URI photographs and executable links are never followed.
public enum WhatsAppContactParser {
  public static func parse(_ raw: String, fallbackName: String) -> WhatsAppContactPresentation {
    let fallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
    var result = WhatsAppContactPresentation(
      name: fallback.isEmpty ? "Контакт" : String(fallback.prefix(512)), fields: [],
      isMalformed: false, sourcePreview: String(raw.prefix(16_000)),
      sourceTruncated: raw.count > 16_000)
    guard raw.utf8.count <= 256 * 1024 else {
      result.isMalformed = true
      return result
    }
    var physical = raw.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
    while physical.last == "" { physical.removeLast() }
    guard physical.count <= 2048 else {
      result.isMalformed = true
      return result
    }
    var lines: [String] = []
    for line in physical {
      if line.first == " " || line.first == "\t" {
        guard !lines.isEmpty else {
          result.isMalformed = true
          return result
        }
        lines[lines.count - 1].append(contentsOf: line.dropFirst())
      } else {
        lines.append(line)
      }
    }
    guard lines.first?.uppercased() == "BEGIN:VCARD", lines.last?.uppercased() == "END:VCARD",
      lines.filter({ $0.uppercased() == "BEGIN:VCARD" }).count == 1,
      lines.filter({ $0.uppercased() == "END:VCARD" }).count == 1
    else {
      result.isMalformed = true
      return result
    }
    var fullName: String?
    var structuredName: String?
    for (index, line) in lines.dropFirst().dropLast().enumerated() {
      guard let colon = delimiter(in: line, character: ":") else {
        result.isMalformed = true
        continue
      }
      let header = String(line[..<colon])
      let pieces = header.split(separator: ";", omittingEmptySubsequences: false)
      let key = pieces.first?.split(separator: ".").last?.uppercased() ?? ""
      let encoded = String(line[line.index(after: colon)...])
      let value = unescape(encoded).trimmingCharacters(in: .whitespacesAndNewlines)
      switch key {
      case "VERSION":
        if value != "3.0" && value != "4.0" { result.isMalformed = true }
      case "FN": if fullName == nil && !value.isEmpty { fullName = value }
      case "N":
        let parts = components(encoded).map {
          unescape($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if parts.count == 5 {
          let name = [parts[3], parts[1], parts[2], parts[0], parts[4]].filter { !$0.isEmpty }
            .joined(separator: " ")
          if !name.isEmpty { structuredName = name }
        } else {
          result.isMalformed = true
        }
      case "TEL", "EMAIL", "ORG":
        guard !value.isEmpty else { continue }
        guard result.fields.count < 128 else {
          result.isMalformed = true
          continue
        }
        let kind: WhatsAppContactField.Kind =
          key == "TEL" ? .phone : key == "EMAIL" ? .email : .organization
        let display: String
        if key == "ORG" {
          display = components(encoded).map {
            unescape($0).trimmingCharacters(in: .whitespacesAndNewlines)
          }
          .filter { !$0.isEmpty }.joined(separator: " · ")
        } else if key == "TEL", value.lowercased().hasPrefix("tel:") {
          display = String(value.dropFirst(4))
        } else {
          display = value
        }
        if !display.isEmpty {
          result.fields.append(
            .init(
              kind: kind, label: label(kind, header: header),
              value: String(display.prefix(4096)), stableID: index))
        }
      default: break
      }
    }
    if let name = fullName ?? structuredName { result.name = String(name.prefix(512)) }
    return result
  }
  private static func label(_ kind: WhatsAppContactField.Kind, header: String) -> String {
    if kind == .organization { return "Организация" }
    let upper = header.uppercased()
    if upper.contains("CELL") { return "Мобильный" }
    if upper.contains("WORK") { return "Рабочий" }
    if upper.contains("HOME") { return "Домашний" }
    return kind == .phone ? "Телефон" : "Почта"
  }
  private static func delimiter(in value: String, character: Character) -> String.Index? {
    var quoted = false
    var escaped = false
    for i in value.indices {
      let c = value[i]
      if escaped {
        escaped = false
        continue
      }
      if c == "\\" {
        escaped = true
        continue
      }
      if c == "\"" { quoted.toggle() }
      if c == character && !quoted { return i }
    }
    return nil
  }
  private static func components(_ value: String) -> [String] {
    var values = [String]()
    var current = ""
    var escaped = false
    for c in value {
      if c == ";" && !escaped {
        values.append(current)
        current = ""
      } else {
        current.append(c)
      }
      if escaped { escaped = false } else if c == "\\" { escaped = true }
    }
    values.append(current)
    return values
  }
  private static func unescape(_ value: String) -> String {
    var result = ""
    var escaped = false
    for c in value {
      if escaped {
        result.append(c == "n" || c == "N" ? "\n" : c)
        escaped = false
      } else if c == "\\" {
        escaped = true
      } else {
        result.append(c)
      }
    }
    if escaped { result.append("\\") }
    return result
  }
}
