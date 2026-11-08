import Foundation

/// Google Calendar API v3 JSON to and from the calendar model.
enum GoogleCalendarMapping {
    struct Time: Codable {
        var date: String?
        var dateTime: String?
        var timeZone: String?
    }
    struct Attendee: Codable {
        var email: String?
        var displayName: String?
        var responseStatus: String?
        var isSelf: Bool?
        var organizer: Bool?
        enum CodingKeys: String, CodingKey { case email, displayName, responseStatus, isSelf = "self", organizer }
    }
    struct Person: Codable { var email: String? }
    struct Reminders: Codable {
        struct Override: Codable {
            var method: String?
            var minutes: Int
        }
        var useDefault: Bool?
        var overrides: [Override]?
    }
    struct Properties: Codable { var `private`: [String: String]? }
    struct EntryPoint: Codable {
        var entryPointType: String?
        var uri: String?
    }
    struct Conference: Codable { var entryPoints: [EntryPoint]? }
    struct Event: Codable {
        var id: String?
        var etag: String?
        var iCalUID: String?
        var status: String?
        var summary: String?
        var description: String?
        var location: String?
        var start: Time?
        var end: Time?
        var recurrence: [String]?
        var recurringEventId: String?
        var originalStartTime: Time?
        var organizer: Person?
        var attendees: [Attendee]?
        var reminders: Reminders?
        var transparency: String?
        var hangoutLink: String?
        var conferenceData: Conference?
        var extendedProperties: Properties?
    }
    struct Page: Decodable {
        var items: [Event]?
        var nextPageToken: String?
        var nextSyncToken: String?
    }
    struct ListEntry: Decodable {
        var id: String
        var summary: String?
        var summaryOverride: String?
        var backgroundColor: String?
        var accessRole: String?
    }
    struct CalendarList: Decodable {
        var items: [ListEntry]?
        var nextPageToken: String?
    }

    static let busyKey = "makoshBusy", taskKey = "makoshTask"

    nonisolated(unsafe) static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func instant(_ text: String) -> Date? { isoPlain.date(from: text) ?? isoFractional.date(from: text) }

    static func day(_ text: String) -> CalendarDay? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? CalendarDay(year: parts[0], month: parts[1], day: parts[2]) : nil
    }
    static func dayText(_ day: CalendarDay) -> String { String(format: "%04d-%02d-%02d", day.year, day.month, day.day) }

    static func moment(_ time: Time?) -> Date? {
        guard let time else { return nil }
        if let text = time.dateTime { return instant(text) }
        if let text = time.date, let day = day(text) { return CalendarRecurrenceExpander.midnight(day) }
        return nil
    }

    static func busyMarker(_ text: String?) -> CalendarBusyMarker? {
        guard let parts = text?.split(separator: ";", maxSplits: 1), parts.count == 2, let source = UUID(uuidString: String(parts[0])),
            let key = instant(String(parts[1]))
        else { return nil }
        return CalendarBusyMarker(sourceEventID: source, occurrenceStart: key)
    }
    static func busyText(_ marker: CalendarBusyMarker) -> String {
        marker.sourceEventID.uuidString + ";" + isoPlain.string(from: marker.occurrenceStart)
    }

    static func response(_ text: String?) -> CalendarResponse {
        switch text {
        case "accepted": .accepted
        case "tentative": .tentative
        case "declined": .declined
        default: .needsAction
        }
    }
    static func responseText(_ response: CalendarResponse) -> String {
        switch response {
        case .needsAction: "needsAction"
        case .accepted: "accepted"
        case .tentative: "tentative"
        case .declined: "declined"
        }
    }

    /// An event as the model sees it; nil for a plain removal (status cancelled, no series).
    static func event(_ item: Event, collectionID: UUID) -> CalendarEvent? {
        guard let id = item.id else { return nil }
        let uid = item.iCalUID ?? id
        let time: CalendarEventTime
        if let startDay = item.start?.date.flatMap(day) {
            let endDay = item.end?.date.flatMap(day) ?? ICalendar.adding(days: 1, to: startDay)
            time = .allDay(start: startDay, endExclusive: max(endDay, ICalendar.adding(days: 1, to: startDay)))
        } else if let start = item.start?.dateTime.flatMap(instant) {
            let end = item.end?.dateTime.flatMap(instant) ?? start.addingTimeInterval(3600)
            time = .timed(start: start, end: max(end, start), timeZone: item.start?.timeZone)
        } else if item.status == "cancelled", item.recurringEventId != nil, let original = moment(item.originalStartTime) {
            time = .timed(start: original, end: original, timeZone: nil)
        } else {
            return nil
        }
        var event = CalendarEvent(
            collectionID: collectionID, externalID: id, uid: uid, title: item.summary ?? "", notes: item.description ?? "",
            location: item.location ?? "", time: time, etag: item.etag)
        if let lines = item.recurrence {
            var rule: String?
            var exdates: [Date] = []
            for raw in lines {
                guard let line = ICalendar.parseLine(raw) else { continue }
                if line.name == "RRULE" { rule = line.value }
                if line.name == "EXDATE" {
                    for value in line.value.split(separator: ",") {
                        if let moment = ICalendar.moment(String(value), parameters: line.parameters) {
                            exdates.append(ICalendar.instant(of: moment))
                        }
                    }
                }
            }
            if let rule { event.recurrence = CalendarRecurrence(rrule: rule, exdates: exdates) }
        }
        if item.recurringEventId != nil { event.recurrenceID = moment(item.originalStartTime) }
        event.organizerEmail = item.organizer?.email
        event.attendees = (item.attendees ?? []).compactMap { attendee in
            attendee.email.map {
                CalendarAttendee(
                    email: $0, name: attendee.displayName, response: response(attendee.responseStatus), isSelf: attendee.isSelf ?? false,
                    isOrganizer: attendee.organizer ?? false)
            }
        }
        if item.reminders?.useDefault != true { event.reminders = (item.reminders?.overrides ?? []).map(\.minutes) }
        if item.transparency == "transparent" { event.transparency = .free }
        switch item.status {
        case "cancelled": event.status = .cancelled
        case "tentative": event.status = .tentative
        default: break
        }
        let video = item.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri ?? item.hangoutLink
        event.meetingURL =
            video.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
            ?? CalendarMeetingLink.telemost(in: event.location) ?? CalendarMeetingLink.telemost(in: event.notes)
        event.busyMarker = busyMarker(item.extendedProperties?.private?[busyKey])
        event.taskID = item.extendedProperties?.private?[taskKey].flatMap(UUID.init(uuidString:))
        return event
    }

    static func time(_ time: CalendarEventTime) -> (Time, Time) {
        switch time {
        case .allDay(let start, let end): (Time(date: dayText(start)), Time(date: dayText(end)))
        case .timed(let start, let end, let zone):
            (Time(dateTime: isoPlain.string(from: start), timeZone: zone), Time(dateTime: isoPlain.string(from: end), timeZone: zone))
        }
    }

    /// The body Makosh writes for an original. Organizer and status stay Google's.
    static func body(_ event: CalendarEvent) -> Event {
        let (start, end) = time(event.time)
        var body = Event(
            summary: event.title, description: event.notes, location: event.location, start: start, end: end,
            reminders: Reminders(
                useDefault: event.reminders.isEmpty,
                overrides: event.reminders.isEmpty ? nil : event.reminders.map { .init(method: "popup", minutes: $0) }),
            transparency: event.transparency == .free ? "transparent" : "opaque")
        if let recurrence = event.recurrence {
            body.recurrence = ["RRULE:" + recurrence.rrule] + recurrence.exdates.map { "EXDATE:" + ICalendar.utc($0) }
        }
        if !event.attendees.isEmpty {
            body.attendees = event.attendees.map {
                Attendee(
                    email: $0.email, displayName: $0.name, responseStatus: $0.isSelf ? responseText($0.response) : nil, isSelf: nil,
                    organizer: nil)
            }
        }
        if let task = event.taskID { body.extendedProperties = Properties(private: [taskKey: task.uuidString]) }
        return body
    }

    static func busyBody(time value: CalendarEventTime, marker: CalendarBusyMarker) -> Event {
        let (start, end) = time(value)
        return Event(
            summary: "Занято", start: start, end: end, reminders: Reminders(useDefault: false, overrides: nil), transparency: "opaque",
            extendedProperties: Properties(private: [busyKey: busyText(marker)]))
    }
}

extension GoogleCalendarMapping.Event {
    init(
        summary: String? = nil, description: String? = nil, location: String? = nil, start: GoogleCalendarMapping.Time? = nil,
        end: GoogleCalendarMapping.Time? = nil, reminders: GoogleCalendarMapping.Reminders? = nil, transparency: String? = nil,
        extendedProperties: GoogleCalendarMapping.Properties? = nil
    ) {
        self.init(
            id: nil, etag: nil, iCalUID: nil, status: nil, summary: summary, description: description, location: location, start: start,
            end: end, recurrence: nil, recurringEventId: nil, originalStartTime: nil, organizer: nil, attendees: nil, reminders: reminders,
            transparency: transparency, hangoutLink: nil, conferenceData: nil, extendedProperties: extendedProperties)
    }
}
