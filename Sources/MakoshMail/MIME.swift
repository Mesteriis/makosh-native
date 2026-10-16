// Derived from MMail, copyright (c) 2026 moerdowo, MIT.
// Pinned source and retained notice: Dependencies/Mail.lock.json, Dependencies/Mail/MMail.MIT.notice.
// Makosh adaptations are recorded in docs/mail-migration.md.
import Foundation

// Pragmatic MIME helpers: RFC 2047 header decoding, outgoing message building,
// and a minimal text-part extractor for incoming messages.
enum MIME {

    // MARK: RFC 2047 encoded-word header decoding ("=?utf-8?B?...?=")

    static func decodeHeader(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var result = ""
        var rest = Substring(input)
        while let start = rest.range(of: "=?") {
            result += rest[rest.startIndex..<start.lowerBound]
            let after = rest[start.upperBound...]
            // charset?enc?text?=
            guard let q1 = after.range(of: "?"),
                  let q2 = after[q1.upperBound...].range(of: "?"),
                  let end = after[q2.upperBound...].range(of: "?=") else {
                result += "=?"; rest = after; continue
            }
            let charset = String(after[after.startIndex..<q1.lowerBound])
            let enc = String(after[q1.upperBound..<q2.lowerBound]).uppercased()
            let text = String(after[q2.upperBound..<end.lowerBound])
            if let decoded = decodeWord(text, encoding: enc, charset: charset) {
                result += decoded
            } else {
                result += text
            }
            rest = after[end.upperBound...]
        }
        result += rest
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeWord(_ text: String, encoding: String, charset: String) -> String? {
        let data: Data?
        if encoding == "B" {
            data = Data(base64Encoded: text)
        } else { // "Q" — quoted-printable variant (underscore = space)
            data = quotedPrintableData(text.replacingOccurrences(of: "_", with: " "), underscoreSpace: true)
        }
        guard let d = data else { return nil }
        return string(from: d, charset: charset)
    }

    // MARK: Outgoing message

    static func buildMessage(from: String, fromName: String?, to: String, cc: String = "",
                             subject: String, body: String, date: Date = Date(),
                             attachments: [ComposeAttachment] = [], bodyHTML: String? = nil) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        let dateStr = df.string(from: date)
        // Message-ID must use the sender's real domain; a bogus host (e.g. .local)
        // is a common spam signal.
        let senderDomain = from.split(separator: "@").last.map(String.init) ?? "localhost"
        let messageID = "<\(UUID().uuidString)@\(senderDomain)>"
        let fromHeader: String
        if let name = fromName, !name.isEmpty {
            fromHeader = "\(encodeWordIfNeeded(name)) <\(from)>"
        } else {
            fromHeader = from
        }
        let bodyData = Data(body.utf8)
        let encodedBody = bodyData.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])

        var headers: [String] = []
        headers.append("From: \(fromHeader)")
        headers.append("To: \(to)")
        if !cc.trimmingCharacters(in: .whitespaces).isEmpty { headers.append("Cc: \(cc)") }
        headers.append("Subject: \(encodeWordIfNeeded(subject))")
        headers.append("Date: \(dateStr)")
        headers.append("Message-ID: \(messageID)")
        headers.append("MIME-Version: 1.0")

        let htmlEncoded = bodyHTML.map {
            Data($0.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        }
        let plainPart = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        let htmlPart = "Content-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"

        // Plain text only, no attachments.
        if htmlEncoded == nil && attachments.isEmpty {
            headers.append("Content-Type: text/plain; charset=utf-8")
            headers.append("Content-Transfer-Encoding: base64")
            return headers.joined(separator: "\r\n") + "\r\n\r\n" + encodedBody + "\r\n"
        }

        // The body entity: a multipart/alternative when we have HTML, else plain.
        func alternativeBlock(_ boundary: String) -> String {
            var s = "--\(boundary)\r\n" + plainPart + encodedBody + "\r\n"
            if let htmlEncoded { s += "--\(boundary)\r\n" + htmlPart + htmlEncoded + "\r\n" }
            s += "--\(boundary)--\r\n"
            return s
        }

        // HTML body, no attachments → top-level multipart/alternative.
        if let _ = htmlEncoded, attachments.isEmpty {
            let altB = "MMail-alt-\(UUID().uuidString)"
            headers.append("Content-Type: multipart/alternative; boundary=\"\(altB)\"")
            return headers.joined(separator: "\r\n") + "\r\n\r\n" + alternativeBlock(altB)
        }

        // Attachments present → multipart/mixed wrapping the body + attachment parts.
        let mixB = "MMail-\(UUID().uuidString)"
        headers.append("Content-Type: multipart/mixed; boundary=\"\(mixB)\"")
        var out = headers.joined(separator: "\r\n") + "\r\n\r\n"
        out += "This is a multi-part message in MIME format.\r\n"
        out += "--\(mixB)\r\n"
        if htmlEncoded != nil {
            let altB = "MMail-alt-\(UUID().uuidString)"
            out += "Content-Type: multipart/alternative; boundary=\"\(altB)\"\r\n\r\n"
            out += alternativeBlock(altB)
        } else {
            out += plainPart + encodedBody + "\r\n"
        }
        for att in attachments {
            let encoded = att.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            out += "--\(mixB)\r\n"
            out += "Content-Type: \(att.mimeType); name=\"\(att.filename)\"\r\n"
            out += "Content-Transfer-Encoding: base64\r\n"
            out += "Content-Disposition: attachment; filename=\"\(att.filename)\"\r\n\r\n"
            out += encoded + "\r\n"
        }
        out += "--\(mixB)--\r\n"
        return out
    }

    private static func encodeWordIfNeeded(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII && !$0.isNewline && $0 != "\0" }) { return s }
        let b64 = Data(s.utf8).base64EncodedString()
        return "=?utf-8?B?\(b64)?="
    }

    // MARK: Incoming text + attachment extraction

    struct Attachment { let filename: String; let mimeType: String; let data: Data }
    struct Parsed { var text: String; var html: String?; var attachments: [Attachment]; var listUnsubscribe: String?; var calendar: String?; var headers: [String: String] = [:] }

    static func extractText(from data: Data) -> String { parse(data).text }

    static func parse(_ data: Data) -> Parsed {
        var result = Parsed(text: "", html: nil, attachments: [], listUnsubscribe: nil, calendar: nil)
        result.headers = splitHeadersBody(data).headers
        walk(data, into: &result)
        if result.text.isEmpty, let html = result.html { result.text = stripHTML(html) }
        return result
    }

    private static func walk(_ data: Data, into result: inout Parsed, depth: Int = 0) {
        guard depth < 32, data.count <= 32 * 1024 * 1024 else { return }
        let (headers, body) = splitHeadersBody(data)
        if result.listUnsubscribe == nil, let lu = headers["list-unsubscribe"] { result.listUnsubscribe = lu }
        let ct = headers["content-type"] ?? "text/plain"
        let ctl = ct.lowercased()
        let enc = (headers["content-transfer-encoding"] ?? "").lowercased()
        let disp = (headers["content-disposition"] ?? "").lowercased()
        let filename = parameter("filename", in: headers["content-disposition"] ?? "") ?? parameter("name", in: ct)

        if ctl.contains("multipart/"), let boundary = parameter("boundary", in: ct) {
            for part in splitParts(body, boundary: boundary) { walk(part, into: &result, depth: depth + 1) }
            return
        }

        // Calendar invite (text/calendar part, or a .ics attachment).
        let isICS = ctl.contains("text/calendar") || ctl.contains("application/ics")
            || (filename?.lowercased().hasSuffix(".ics") ?? false)
        if isICS {
            let decoded = decodeBody(body, encoding: enc)
            if result.calendar == nil {
                result.calendar = string(from: decoded, charset: parameter("charset", in: ct) ?? "utf-8")
                    ?? String(decoding: decoded, as: UTF8.self)
            }
            let filename = filename ?? "invitation.ics"
            result.attachments.append(Attachment(filename: decodeHeader(filename), mimeType: "text/calendar", data: decoded))
            return
        }

        // Attachment: explicit disposition, or a named non-text part.
        if disp.contains("attachment") || !ctl.hasPrefix("text/") {
            let filename = filename ?? "attachment-\(result.attachments.count + 1)"
            let decoded = decodeBody(body, encoding: enc)
            result.attachments.append(Attachment(filename: decodeHeader(filename),
                                                  mimeType: ctl.split(separator: ";").first.map(String.init) ?? ctl,
                                                  data: decoded))
            return
        }

        // Text content (prefer the first text/plain; keep html as a fallback).
        let decoded = decodeBody(body, encoding: enc)
        let charset = parameter("charset", in: ct) ?? "utf-8"
        let text = string(from: decoded, charset: charset) ?? String(decoding: decoded, as: UTF8.self)
        if ctl.contains("text/html") {
            if result.html == nil { result.html = text }
        } else if result.text.isEmpty {
            result.text = text
        }
    }

    // MARK: iCalendar (.ics) parsing

    static func parseICS(_ ics: String) -> CalendarEvent? {
        // Unfold RFC 5545 continuation lines, then read the VEVENT properties.
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        var summary = "", location = "", organizer = ""
        var start: Date?, end: Date?
        for rawLine in unfolded.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let keyPart = String(line[line.startIndex..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let key = keyPart.split(separator: ";").first.map { String($0).uppercased() } ?? keyPart.uppercased()
            switch key {
            case "SUMMARY": summary = unescapeICS(value)
            case "LOCATION": location = unescapeICS(value)
            case "ORGANIZER":
                if let cn = keyPart.range(of: "CN=", options: .caseInsensitive) {
                    organizer = String(keyPart[cn.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                } else {
                    organizer = value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
                }
            case "DTSTART": start = icsDate(value)
            case "DTEND": end = icsDate(value)
            default: break
            }
        }
        guard !summary.isEmpty || start != nil else { return nil }
        return CalendarEvent(summary: summary.isEmpty ? "(untitled event)" : summary,
                             start: start, end: end,
                             location: location.isEmpty ? nil : location,
                             organizer: organizer.isEmpty ? nil : organizer, raw: ics)
    }

    private static func unescapeICS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func icsDate(_ value: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for (fmt, utc) in [("yyyyMMdd'T'HHmmss'Z'", true), ("yyyyMMdd'T'HHmmss", false), ("yyyyMMdd", false)] {
            f.dateFormat = fmt
            f.timeZone = utc ? TimeZone(identifier: "UTC") : TimeZone.current
            if let d = f.date(from: value) { return d }
        }
        return nil
    }

    // MARK: Low-level parsing

    private static func splitHeadersBody(_ data: Data) -> (headers: [String: String], body: Data) {
        let marker = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8))
        guard let marker else { return ([:], data) }
        return (parseHeaders(String(decoding: data[..<marker.lowerBound], as: UTF8.self)), Data(data[marker.upperBound...]))
    }

    private static func parseHeaders(_ text: String) -> [String: String] {
        var map: [String: String] = [:]
        var currentKey: String?
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let first = line.first, first == " " || first == "\t", let key = currentKey {
                map[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                map[key] = value
                currentKey = key
            }
        }
        return map
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        var pieces: [String] = [], current = "", quoted = false, escaped = false
        for character in header {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if character == ";", !quoted { pieces.append(current); current = "" } else { current.append(character) }
        }
        pieces.append(current)
        var parameters: [String: String] = [:]
        for piece in pieces {
            guard let separator = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            parameters[key] = piece[piece.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        let key = name.lowercased()
        if let extended = parameters[key + "*"], let decoded = decodeExtended(extended) { return decoded }
        if parameters[key + "*0*"] != nil {
            var combined = "", index = 0
            while let part = parameters[key + "*\(index)*"] ?? parameters[key + "*\(index)"] { combined += part; index += 1; if index > 100 { break } }
            if let decoded = decodeExtended(combined) { return decoded }
        }
        return parameters[key]
    }
    private static func decodeExtended(_ value: String) -> String? {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let bytes = Array(parts[2].utf8)
        var result = Data(), index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, let number = UInt8(String(decoding: bytes[(index+1)...(index+2)], as: UTF8.self), radix: 16) else { return nil }
                result.append(number); index += 3
            } else { result.append(bytes[index]); index += 1 }
        }
        return string(from: result, charset: String(parts[0]))
    }

    private static func splitParts(_ body: Data, boundary: String) -> [Data] {
        guard !boundary.isEmpty, boundary.utf8.count <= 200 else { return [] }
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [Data] = [], partStart: Int? = nil
        var cursor = 0
        while cursor < body.count {
            let lineEnd = body.range(of: Data([10]),in: cursor..<body.count)?.lowerBound ?? body.count
            var line = Data(body[cursor..<lineEnd]); if line.last == 13 { line.removeLast() }
            let closing = line == delimiter + Data("--".utf8)
            if line == delimiter || closing {
                if let start = partStart {
                    var end = cursor
                    if end >= 2, body[end-2] == 13, body[end-1] == 10 { end -= 2 }
                    else if end > 0, body[end-1] == 10 { end -= 1 }
                    if start < end { parts.append(Data(body[start..<end])) }
                }
                if closing { break }
                partStart = min(lineEnd+1,body.count)
            }
            cursor = lineEnd+1
        }
        return parts
    }

    private static func decodeBody(_ data: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let s = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            return Data(base64Encoded: s) ?? data
        case "quoted-printable":
            return quotedPrintableData(String(decoding: data, as: UTF8.self), underscoreSpace: false) ?? data
        default:
            return data
        }
    }

    private static func quotedPrintableData(_ s: String, underscoreSpace: Bool) -> Data? {
        // Operate on raw UTF-8 octets, NOT Characters. Swift treats "\r\n" as a
        // single Character (extended grapheme cluster), so a char-based scan can
        // never match `=` then `\r` then `\n` as separate units and silently
        // leaves CRLF soft line breaks (`=\r\n`) undecoded — which is exactly how
        // RFC-compliant email wraps quoted-printable. Quoted-printable is defined
        // on octets anyway, so decode over bytes.
        let bytes = Array(s.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30          // 0–9
            case 0x41...0x46: return b - 0x41 + 10     // A–F
            case 0x61...0x66: return b - 0x61 + 10     // a–f
            default: return nil
            }
        }
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D {  // '='
                // Soft line break: "=\r\n", "=\n", or a bare "=\r".
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { i += 3; continue }
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { i += 2; continue }
                if i + 1 < bytes.count, bytes[i + 1] == 0x0D { i += 2; continue }
                // "=XX" hex escape.
                if i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                    out.append(hi << 4 | lo); i += 3; continue
                }
                out.append(0x3D); i += 1   // stray '=' — keep literal
            } else if b == 0x5F, underscoreSpace {  // '_'
                out.append(0x20); i += 1
            } else {
                out.append(b); i += 1
            }
        }
        return Data(out)
    }

    private static func string(from data: Data, charset: String) -> String? {
        switch charset.lowercased() {
        case "utf-8", "utf8", "us-ascii", "ascii":
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        case "iso-8859-1", "latin1", "iso8859-1":
            return String(data: data, encoding: .isoLatin1)
        case "windows-1252", "cp1252":
            return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
        default:
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var text = html
        for (tag, repl) in [("<br>", "\n"), ("<br/>", "\n"), ("<br />", "\n"), ("</p>", "\n\n"), ("</div>", "\n")] {
            text = text.replacingOccurrences(of: tag, with: repl, options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (e, r) in entities { text = text.replacingOccurrences(of: e, with: r) }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
}
