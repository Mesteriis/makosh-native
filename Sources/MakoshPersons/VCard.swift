import Foundation
import MakoshCore

/// vCard 3.0 for CardDAV servers: what Makosh writes and the subset it reads back.
public enum VCard {
    public enum Failure: Error, Equatable { case notAVCard, noName }
    static let marker = "X-MAKOSH-PERSON"

    public struct Parsed: Equatable, Sendable {
        public var imported: ImportedPerson
        public var makoshID: UUID?
        public var kind: PersonKind
        public var uid: String?
    }

    // MARK: Writing

    public static func serialize(_ card: PersonCard) -> String {
        var lines: [String] = ["BEGIN:VCARD", "VERSION:3.0", "UID:" + card.makoshID.uuidString, "FN:" + escape(card.displayName)]
        if card.kind == .organization {
            lines.append("X-ABShowAs:COMPANY")
            lines.append("KIND:org")
            lines.append("ORG:" + escape(card.displayName))
        } else {
            lines.append("N:" + [card.familyName, card.givenName, card.middleName, "", ""].map(escape).joined(separator: ";"))
            if !card.organization.isEmpty { lines.append("ORG:" + escape(card.organization)) }
        }
        if !card.jobTitle.isEmpty { lines.append("TITLE:" + escape(card.jobTitle)) }
        for phone in card.phones { lines.append("TEL;TYPE=CELL,VOICE:" + escape(phone)) }
        for email in card.emails { lines.append("EMAIL;TYPE=INTERNET:" + escape(email)) }
        lines.append(marker + ":" + card.makoshID.uuidString)
        lines.append("END:VCARD")
        return lines.flatMap(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ";", with: "\\;")
    }

    /// RFC 5545 §3.1 folding at 75 octets, never inside a UTF-8 sequence.
    static func fold(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentBytes = 0
        var limit = 75
        for scalar in line.unicodeScalars {
            let size = String(scalar).utf8.count
            if currentBytes + size > limit {
                result.append(current)
                current = " "
                currentBytes = 1
                limit = 75
            }
            current.unicodeScalars.append(scalar)
            currentBytes += size
        }
        result.append(current)
        return result
    }

    // MARK: Reading

    public static func parse(_ text: String) throws -> Parsed {
        let unfolded = unfold(text)
        guard unfolded.first?.uppercased() == "BEGIN:VCARD" else { throw Failure.notAVCard }
        var displayName: String?
        var given = "", family = "", middle = ""
        var organization: String?, title: String?
        var phones: [String] = [], emails: [String] = [], notes: [String] = []
        var makoshID: UUID?, uid: String?
        var kind = PersonKind.person
        for line in unfolded.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[..<colon]), rawValue = String(line[line.index(after: colon)...])
            let name = head.split(separator: ";", maxSplits: 1).first.map { String($0).uppercased() } ?? head.uppercased()
            switch name {
            case "FN": displayName = unescape(rawValue)
            case "N":
                let parts = splitUnescaped(rawValue, separator: ";")
                family = parts.count > 0 ? parts[0] : ""
                given = parts.count > 1 ? parts[1] : ""
                middle = parts.count > 2 ? parts[2] : ""
            case "ORG": organization = splitUnescaped(rawValue, separator: ";").first ?? ""
            case "TITLE": title = unescape(rawValue)
            case "TEL": phones.append(unescape(rawValue))
            case "EMAIL": emails.append(unescape(rawValue))
            case "NOTE": notes.append(unescape(rawValue))
            case "UID": uid = unescape(rawValue)
            case marker: makoshID = UUID(uuidString: unescape(rawValue))
            case "X-ABSHOWAS": if unescape(rawValue).uppercased() == "COMPANY" { kind = .organization }
            case "KIND": if unescape(rawValue).lowercased() == "org" { kind = .organization }
            default: continue
            }
        }
        guard let name = displayName.map({ $0.trimmingCharacters(in: .whitespaces) }), !name.isEmpty else { throw Failure.noName }
        let imported = ImportedPerson(
            externalID: uid ?? name, displayName: name, givenName: given.isEmpty ? nil : given, familyName: family.isEmpty ? nil : family,
            middleName: middle.isEmpty ? nil : middle, organization: organization, jobTitle: title, phones: phones, emails: emails,
            notes: notes)
        return Parsed(imported: imported, makoshID: makoshID, kind: kind, uid: uid)
    }

    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }

    static func unescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n", "N": result.append("\n")
            default: result.append(next)
            }
        }
        return result
    }

    /// Splits on an unescaped separator, then unescapes each part.
    static func splitUnescaped(_ value: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in value {
            if escaped {
                current.append("\\")
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == separator {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map(unescape)
    }
}
