import Foundation

/// RFC 5545 reading and writing for the events Makosh exchanges with CalDAV
/// servers and link subscriptions. Time zones are IANA names; an unknown
/// `TZID` falls back to UTC.
public enum ICalendar {
    static let busyProperty = "X-MAKOSH-BUSY"
    static let taskProperty = "X-MAKOSH-TASK"

    // MARK: Reading

    struct Line {
        let name: String
        let parameters: [String: String]
        let value: String
    }

    public static func parse(_ text: String, collectionID: UUID) throws -> [CalendarEvent] {
        let lines = unfold(text).compactMap(parseLine)
        guard lines.contains(where: { $0.name == "BEGIN" && $0.value.uppercased() == "VCALENDAR" }) else {
            throw CalendarFailure.invalidInput("not a calendar")
        }
        var events: [CalendarEvent] = []
        var current: [Line]?
        var alarms: [[Line]] = []
        var alarm: [Line]?
        var depth = 0
        for line in lines {
            let value = line.value.uppercased()
            if line.name == "BEGIN" {
                if value == "VEVENT" {
                    current = []
                    alarms = []
                } else if value == "VALARM", current != nil {
                    alarm = []
                } else if current != nil {
                    depth += 1
                }
                continue
            }
            if line.name == "END" {
                if value == "VEVENT", let body = current {
                    if let event = makeEvent(body, alarms: alarms, collectionID: collectionID) { events.append(event) }
                    current = nil
                } else if value == "VALARM", let body = alarm {
                    alarms.append(body)
                    alarm = nil
                } else if current != nil, depth > 0 {
                    depth -= 1
                }
                continue
            }
            if alarm != nil {
                alarm?.append(line)
            } else if depth == 0 {
                current?.append(line)
            }
        }
        return events
    }

    static func unfold(_ text: String) -> [String] {
        var result: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false)
        {
            if let first = raw.first, first == " " || first == "\t", !result.isEmpty {
                result[result.count - 1] += raw.dropFirst()
            } else {
                result.append(String(raw))
            }
        }
        return result.filter { !$0.isEmpty }
    }

    static func parseLine(_ line: String) -> Line? {
        var quoted = false
        var colon: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == "\"" { quoted.toggle() }
            if character == ":", !quoted {
                colon = index
                break
            }
        }
        guard let colon else { return nil }
        let head = line[..<colon], value = String(line[line.index(after: colon)...])
        var parts: [String] = []
        var part = ""
        quoted = false
        for character in head {
            if character == "\"" {
                quoted.toggle()
                continue
            }
            if character == ";", !quoted {
                parts.append(part)
                part = ""
            } else {
                part.append(character)
            }
        }
        parts.append(part)
        guard let name = parts.first?.uppercased(), !name.isEmpty else { return nil }
        var parameters: [String: String] = [:]
        for parameter in parts.dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { parameters[pair[0].uppercased()] = String(pair[1]) }
        }
        return Line(name: name, parameters: parameters, value: value)
    }

    static func unescape(_ value: String) -> String {
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    enum Moment {
        case day(CalendarDay)
        case instant(Date, zone: String?)
    }

    static func moment(_ value: String, parameters: [String: String]) -> Moment? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if parameters["VALUE"]?.uppercased() == "DATE" || (text.count == 8 && text.allSatisfy(\.isNumber)) {
            guard text.count == 8, let year = Int(text.prefix(4)), let month = Int(text.dropFirst(4).prefix(2)),
                let day = Int(text.suffix(2))
            else { return nil }
            return .day(CalendarDay(year: year, month: month, day: day))
        }
        let utc = text.hasSuffix("Z")
        let digits = utc ? String(text.dropLast()) : text
        guard digits.count == 15, digits[digits.index(digits.startIndex, offsetBy: 8)] == "T" else { return nil }
        let date = digits.prefix(8), time = digits.suffix(6)
        guard let year = Int(date.prefix(4)), let month = Int(date.dropFirst(4).prefix(2)), let day = Int(date.suffix(2)),
            let hour = Int(time.prefix(2)), let minute = Int(time.dropFirst(2).prefix(2)), let second = Int(time.suffix(2))
        else { return nil }
        var zoneName: String?
        let zone: TimeZone
        if utc {
            zone = TimeZone(identifier: "UTC")!
        } else if let tzid = parameters["TZID"], let named = TimeZone(identifier: tzid) {
            zone = named
            zoneName = tzid
        } else if parameters["TZID"] != nil {
            zone = TimeZone(identifier: "UTC")!
        } else {
            zone = .current
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard
            let instant = calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
        else { return nil }
        return .instant(instant, zone: zoneName)
    }

    static func duration(_ value: String) -> TimeInterval? {
        var text = Substring(value.uppercased())
        var sign: Double = 1
        if text.first == "-" {
            sign = -1
            text = text.dropFirst()
        } else if text.first == "+" {
            text = text.dropFirst()
        }
        guard text.first == "P" else { return nil }
        text = text.dropFirst()
        var total: Double = 0, number = "", inTime = false
        for character in text {
            if character.isNumber {
                number.append(character)
                continue
            }
            if character == "T" {
                inTime = true
                continue
            }
            guard let amount = Double(number) else { return nil }
            number = ""
            switch (character, inTime) {
            case ("W", _): total += amount * 7 * 86400
            case ("D", _): total += amount * 86400
            case ("H", true): total += amount * 3600
            case ("M", true): total += amount * 60
            case ("S", true): total += amount
            default: return nil
            }
        }
        return number.isEmpty ? sign * total : nil
    }

    static func adding(days: Int, to day: CalendarDay) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        let next = calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: days, to: date)!)
        return CalendarDay(year: next.year!, month: next.month!, day: next.day!)
    }

    static func instant(of moment: Moment) -> Date {
        switch moment {
        case .instant(let date, _): return date
        case .day(let day):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        }
    }

    static func address(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix("mailto:") ? String(trimmed.dropFirst(7)) : trimmed
    }

    static func response(_ value: String?) -> CalendarResponse {
        switch value?.uppercased() {
        case "ACCEPTED": .accepted
        case "TENTATIVE": .tentative
        case "DECLINED": .declined
        default: .needsAction
        }
    }

    static func makeEvent(_ lines: [Line], alarms: [[Line]], collectionID: UUID) -> CalendarEvent? {
        func first(_ name: String) -> Line? { lines.first { $0.name == name } }
        guard let uid = first("UID")?.value, !uid.isEmpty, let startLine = first("DTSTART"),
            let start = moment(startLine.value, parameters: startLine.parameters)
        else { return nil }
        let time: CalendarEventTime
        switch start {
        case .day(let day):
            var end = adding(days: 1, to: day)
            if let line = first("DTEND"), case .day(let value)? = moment(line.value, parameters: line.parameters), value > day {
                end = value
            } else if let line = first("DURATION"), let seconds = duration(line.value), seconds >= 86400 {
                end = adding(days: Int(seconds / 86400), to: day)
            }
            time = .allDay(start: day, endExclusive: end)
        case .instant(let date, let zone):
            var end = date.addingTimeInterval(3600)
            if let line = first("DTEND"), let value = moment(line.value, parameters: line.parameters) {
                end = instant(of: value)
            } else if let line = first("DURATION"), let seconds = duration(line.value) {
                end = date.addingTimeInterval(seconds)
            }
            time = .timed(start: date, end: max(end, date), timeZone: zone)
        }
        var event = CalendarEvent(collectionID: collectionID, uid: uid, title: unescape(first("SUMMARY")?.value ?? ""), time: time)
        event.notes = unescape(first("DESCRIPTION")?.value ?? "")
        event.location = unescape(first("LOCATION")?.value ?? "")
        if let rule = first("RRULE")?.value {
            var exdates: [Date] = []
            for line in lines where line.name == "EXDATE" {
                for value in line.value.split(separator: ",") {
                    if let moment = moment(String(value), parameters: line.parameters) { exdates.append(instant(of: moment)) }
                }
            }
            event.recurrence = CalendarRecurrence(rrule: rule, exdates: exdates)
        }
        if let line = first("RECURRENCE-ID"), let value = moment(line.value, parameters: line.parameters) {
            event.recurrenceID = instant(of: value)
        }
        if let organizer = first("ORGANIZER") { event.organizerEmail = address(organizer.value) }
        event.attendees = lines.filter { $0.name == "ATTENDEE" }.map { line in
            let email = address(line.value)
            return CalendarAttendee(
                email: email, name: line.parameters["CN"].map(unescape), response: response(line.parameters["PARTSTAT"]),
                isOrganizer: email.caseInsensitiveCompare(event.organizerEmail ?? "") == .orderedSame)
        }
        event.reminders = alarms.compactMap { alarm in
            guard let trigger = alarm.first(where: { $0.name == "TRIGGER" }), trigger.parameters["VALUE"]?.uppercased() != "DATE-TIME",
                let seconds = duration(trigger.value), seconds <= 0
            else { return nil }
            return Int((-seconds / 60).rounded())
        }
        if first("TRANSP")?.value.uppercased() == "TRANSPARENT" { event.transparency = .free }
        switch first("STATUS")?.value.uppercased() {
        case "CANCELLED": event.status = .cancelled
        case "TENTATIVE": event.status = .tentative
        default: break
        }
        if let link = first("URL").flatMap({ URL(string: $0.value.trimmingCharacters(in: .whitespaces)) }), link.scheme == "https" {
            event.meetingURL = link
        } else {
            event.meetingURL = CalendarMeetingLink.telemost(in: event.location) ?? CalendarMeetingLink.telemost(in: event.notes)
        }
        if let busy = first(busyProperty)?.value {
            let parts = busy.split(separator: ";", maxSplits: 1)
            if parts.count == 2, let source = UUID(uuidString: String(parts[0])), let key = isoParser.date(from: String(parts[1])) {
                event.busyMarker = CalendarBusyMarker(sourceEventID: source, occurrenceStart: key)
            }
        }
        if let task = first(taskProperty)?.value { event.taskID = UUID(uuidString: task.trimmingCharacters(in: .whitespaces)) }
        return event
    }

    nonisolated(unsafe) static let isoParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: Writing

    public static func serialize(_ event: CalendarEvent, overrides: [CalendarEvent] = []) -> String {
        var lines = header()
        lines += eventLines(event)
        for override in overrides { lines += eventLines(override) }
        lines.append("END:VCALENDAR")
        return fold(lines)
    }

    public static func serializeBusyCopy(uid: String, time: CalendarEventTime, marker: CalendarBusyMarker) -> String {
        var lines = header()
        lines.append("BEGIN:VEVENT")
        lines.append("UID:" + escape(uid))
        lines.append("DTSTAMP:" + utc(Date()))
        lines += timeLines(time)
        lines.append("SUMMARY:Занято")
        lines.append("TRANSP:OPAQUE")
        lines.append("CLASS:PRIVATE")
        lines.append(busyProperty + ":" + marker.sourceEventID.uuidString + ";" + isoParser.string(from: marker.occurrenceStart))
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return fold(lines)
    }

    static func header() -> [String] { ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Makosh//Calendar//RU", "CALSCALE:GREGORIAN"] }

    static func eventLines(_ event: CalendarEvent) -> [String] {
        var lines = ["BEGIN:VEVENT", "UID:" + escape(event.uid), "DTSTAMP:" + utc(Date())]
        lines += timeLines(event.time)
        let allDay: Bool
        if case .allDay = event.time { allDay = true } else { allDay = false }
        if let recurrenceID = event.recurrenceID {
            lines.append(allDay ? "RECURRENCE-ID;VALUE=DATE:" + localDay(recurrenceID) : "RECURRENCE-ID:" + utc(recurrenceID))
        }
        lines.append("SUMMARY:" + escape(event.title))
        if !event.notes.isEmpty { lines.append("DESCRIPTION:" + escape(event.notes)) }
        if !event.location.isEmpty { lines.append("LOCATION:" + escape(event.location)) }
        if let recurrence = event.recurrence {
            lines.append("RRULE:" + recurrence.rrule)
            for date in recurrence.exdates { lines.append(exdateLine(date, allDay: allDay)) }
        }
        if let organizer = event.organizerEmail { lines.append("ORGANIZER:mailto:" + organizer) }
        for attendee in event.attendees {
            var line = "ATTENDEE"
            if let name = attendee.name { line += ";CN=\"" + name.replacingOccurrences(of: "\"", with: "'") + "\"" }
            line += ";PARTSTAT=" + partstat(attendee.response) + ":mailto:" + attendee.email
            lines.append(line)
        }
        lines.append("TRANSP:" + (event.transparency == .free ? "TRANSPARENT" : "OPAQUE"))
        lines.append("STATUS:" + (event.status == .cancelled ? "CANCELLED" : event.status == .tentative ? "TENTATIVE" : "CONFIRMED"))
        if let url = event.meetingURL { lines.append("URL:" + url.absoluteString) }
        if let task = event.taskID { lines.append(taskProperty + ":" + task.uuidString) }
        for minutes in event.reminders {
            lines += ["BEGIN:VALARM", "ACTION:DISPLAY", "DESCRIPTION:" + escape(event.title), "TRIGGER:-PT\(minutes)M", "END:VALARM"]
        }
        lines.append("END:VEVENT")
        return lines
    }

    static func timeLines(_ time: CalendarEventTime) -> [String] {
        switch time {
        case .allDay(let start, let end):
            return ["DTSTART;VALUE=DATE:" + dayString(start), "DTEND;VALUE=DATE:" + dayString(end)]
        case .timed(let start, let end, let zone):
            if let zone, let named = TimeZone(identifier: zone) {
                return ["DTSTART;TZID=\(zone):" + local(start, named), "DTEND;TZID=\(zone):" + local(end, named)]
            }
            return ["DTSTART:" + utc(start), "DTEND:" + utc(end)]
        }
    }

    static func partstat(_ response: CalendarResponse) -> String {
        switch response {
        case .needsAction: "NEEDS-ACTION"
        case .accepted: "ACCEPTED"
        case .tentative: "TENTATIVE"
        case .declined: "DECLINED"
        }
    }

    /// RFC 5545: exceptions of an all-day series are dates, not instants.
    static func exdateLine(_ date: Date, allDay: Bool) -> String {
        allDay ? "EXDATE;VALUE=DATE:" + localDay(date) : "EXDATE:" + utc(date)
    }

    /// The local calendar day of an instant stored as local midnight.
    static func localDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return dayString(CalendarDay(year: c.year!, month: c.month!, day: c.day!))
    }

    static func dayString(_ day: CalendarDay) -> String { String(format: "%04d%02d%02d", day.year, day.month, day.day) }

    static func local(_ date: Date, _ zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static func utc(_ date: Date) -> String { local(date, TimeZone(identifier: "UTC")!) + "Z" }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Lines of at most 75 octets, continuations start with a space, never splitting a character.
    static func fold(_ lines: [String]) -> String {
        var output = ""
        for line in lines {
            var current = "", size = 0, limit = 75
            for character in line {
                let width = String(character).utf8.count
                if size + width > limit {
                    output += current + "\r\n"
                    current = " "
                    size = 1
                    limit = 75
                }
                current.append(character)
                size += width
            }
            output += current + "\r\n"
        }
        return output
    }
}
