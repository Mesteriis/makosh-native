import Foundation

/// iCalendar texts for the parser tests, kept as strings rather than resources.
enum ICSFixture {
    static func wrap(_ body: String) -> String {
        ("BEGIN:VCALENDAR\nVERSION:2.0\nPRODID:-//Test//RU\n" + body + "END:VCALENDAR\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    static let timedBerlin = wrap(
        """
        BEGIN:VEVENT
        UID:timed-1
        DTSTART;TZID=Europe/Berlin:20261110T100000
        DTEND;TZID=Europe/Berlin:20261110T103000
        SUMMARY:Созвон\\, по плану\\; ок
        DESCRIPTION:Первая строка\\nвторая строка длинного описания, которое перен
         осится на следующую строку
        ORGANIZER;CN=Алиса:mailto:alice@x.test
        ATTENDEE;CN=Алиса;PARTSTAT=ACCEPTED:mailto:alice@x.test
        ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:bob@x.test
        BEGIN:VALARM
        ACTION:DISPLAY
        TRIGGER:-PT15M
        END:VALARM
        END:VEVENT

        """)

    static let allDayNoEnd = wrap(
        """
        BEGIN:VEVENT
        UID:allday-1
        DTSTART;VALUE=DATE:20261120
        SUMMARY:День рождения
        TRANSP:TRANSPARENT
        END:VEVENT

        """)

    static let seriesWithOverride = wrap(
        """
        BEGIN:VEVENT
        UID:series-1
        DTSTART:20261109T090000Z
        DURATION:PT45M
        RRULE:FREQ=WEEKLY;BYDAY=MO
        EXDATE:20261116T090000Z
        EXDATE:20261123T090000Z,20261130T090000Z
        SUMMARY:Планёрка
        END:VEVENT
        BEGIN:VEVENT
        UID:series-1
        RECURRENCE-ID:20261207T090000Z
        DTSTART:20261207T100000Z
        DTEND:20261207T104500Z
        SUMMARY:Планёрка (перенос)
        STATUS:TENTATIVE
        END:VEVENT

        """)

    static let telemostInDescription = wrap(
        """
        BEGIN:VEVENT
        UID:telemost-1
        DTSTART:20261112T120000Z
        DTEND:20261112T130000Z
        SUMMARY:Встреча B
        DESCRIPTION:Ссылка: https://telemost.yandex.ru/j/12345678901234 до встречи
        END:VEVENT

        """)
}
