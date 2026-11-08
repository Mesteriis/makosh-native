import MakoshCalendar
import MakoshCore
import MakoshMail
import SwiftUI

/// Keeps the calendar's attendee hints and CalDAV hints current and opens the section on a reminder click.
struct CalendarWorkspaceLinks: ViewModifier {
    @ObservedObject var host: CalendarHost
    let contacts: [Contact]
    let mailAccounts: [MailAccount]
    var showCalendar: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(host.$openEventRequest.compactMap { $0 }) { _ in showCalendar() }
            .onChange(of: contacts) { _, value in host.contactEmails = Array(Set(value.flatMap(\.emails))).sorted() }
            .onChange(of: mailAccounts) { _, value in host.mailAccounts = value.map { ($0.email, $0.imapHost) } }
    }
}
