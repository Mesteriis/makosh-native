#if DEBUG
import MakoshCalendar
import MakoshCore
import SwiftUI

/// Isolated Calendar QA: one `qa_calendar_` schema on loopback PostgreSQL, synthetic Google,
/// Yandex CalDAV and a holiday feed in memory, one busy group. No other service starts.
struct CalendarSyntheticPreview: View {
    @State private var host: CalendarHost?
    @State private var error: String?
    @State private var settings = false

    var body: some View {
        Group {
            if let host {
                WorkspaceSplitView(width: .constant(280), minimum: 260, maximum: 360, minimumDetail: 700) {
                    CalendarSidebarColumn(host: host).background { WorkspaceBackdrop(intensity: 0.55) }
                } detail: {
                    CalendarDetailView(host: host)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        HStack {
                            Label("СИНТЕТИЧЕСКАЯ ПРОВЕРКА", systemImage: "testtube.2").font(.caption.bold())
                            Button("Настройки календаря") { settings = true }.accessibilityIdentifier("calendar.qa.settings")
                        }
                    }
                }
                .sheet(isPresented: $settings) {
                    VStack {
                        if let model = host.model { CalendarSettingsForm(model: model, host: host).frame(width: 640, height: 560) }
                        Button("Готово") { settings = false }.padding()
                    }.makoshAppearance()
                }
                .environment(\.calendarHost, host)
                .environmentObject(host)
                .environment(\.colorScheme, .dark)
            } else if let error {
                Text(error).padding(24).accessibilityIdentifier("calendar.qa.configurationRequired")
            } else {
                ProgressView("Проверка отдельной конфигурации QA «Календарь»…")
            }
        }
        .task {
            guard host == nil, error == nil else { return }
            let args = CommandLine.arguments
            do {
                let configuration = try await BackgroundWork.run {
                    guard let index = args.firstIndex(of: "--database-config"), args.indices.contains(index + 1) else {
                        throw CalendarQAIsolation.Failure.invalidConfiguration
                    }
                    let file = URL(fileURLWithPath: args[index + 1])
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                        let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0
                    else { throw CalendarQAIsolation.Failure.invalidConfiguration }
                    let value = try JSONDecoder().decode(ContactWorkspaceConfiguration.self, from: Data(contentsOf: file))
                    try CalendarQAIsolation.validate(configuration: value, arguments: args)
                    return value
                }
                let adapters = CalendarSyntheticSeed.adapters(now: Date())
                let host = CalendarHost(synthetic: adapters)
                await host.start(configuration: configuration, taskFeed: CalendarSyntheticTaskFeed()) { _, service in
                    try await CalendarSyntheticSeed.seed(service: service, adapters: adapters, now: Date())
                    await service.settled()
                }
                await host.model?.refresh()
                self.host = host
            } catch {
                self.error =
                    "QA «Календарь» требует --calendar-synthetic-preview и отдельную конфигурацию PostgreSQL со схемой qa_calendar_."
            }
        }
    }
}
#endif
