import Foundation

enum CalDAVFixture {
    static func multistatus(_ body: String) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/" xmlns:cs="http://calendarserver.org/ns/">
            \(body)
            </d:multistatus>
            """.utf8)
    }

    static let principal = multistatus(
        "<d:response><d:href>/.well-known/caldav</d:href><d:propstat><d:prop><d:current-user-principal><d:href>/principals/me/</d:href></d:current-user-principal></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    )

    static let home = multistatus(
        "<d:response><d:href>/principals/me/</d:href><d:propstat><d:prop><c:calendar-home-set><d:href>/calendars/me/</d:href></c:calendar-home-set></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
    )

    static let collections = multistatus(
        """
        <d:response><d:href>/calendars/me/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/calendars/me/work/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Работа B</d:displayname><a:calendar-color>#FF2968FF</a:calendar-color>
          <d:current-user-privilege-set><d:privilege><d:read/></d:privilege><d:privilege><d:write/></d:privilege></d:current-user-privilege-set>
          <c:supported-calendar-component-set><c:comp name="VEVENT"/></c:supported-calendar-component-set><d:sync-token>http://x/sync/1</d:sync-token>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/calendars/me/tasks/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Дела</d:displayname>
          <c:supported-calendar-component-set><c:comp name="VTODO"/></c:supported-calendar-component-set>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/calendars/me/shared/</d:href><d:propstat><d:prop>
          <d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:displayname>Общий</d:displayname>
          <d:current-user-privilege-set><d:privilege><d:read/></d:privilege></d:current-user-privilege-set>
        </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        """)
}
