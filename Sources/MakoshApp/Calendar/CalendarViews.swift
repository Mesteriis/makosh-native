import MakoshCalendar
import SwiftUI

/// The calendar section's left column; filled by the section views.
struct CalendarSidebarColumn: View {
    @ObservedObject var host: CalendarHost
    var body: some View {
        Group {
            if let model = host.model {
                CalendarSidebar(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The calendar section's detail: header, grid and task column.
struct CalendarDetailView: View {
    @ObservedObject var host: CalendarHost
    var body: some View {
        Group {
            if let model = host.model {
                CalendarSection(model: model, host: host)
            } else if let failure = host.failure {
                ContentUnavailableView(failure, systemImage: "calendar.badge.exclamationmark")
            } else {
                ProgressView("Открываю календарь…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct CalendarSidebar: View {
    @ObservedObject var model: CalendarWorkspaceModel
    var body: some View { Text("Календари").frame(maxWidth: .infinity, maxHeight: .infinity) }
}

struct CalendarSection: View {
    @ObservedObject var model: CalendarWorkspaceModel
    @ObservedObject var host: CalendarHost
    var body: some View { Text("Неделя").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
