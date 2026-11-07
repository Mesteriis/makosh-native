#if DEBUG
import MakoshCore
import MakoshTasks
import SwiftUI

/// Isolated Tasks QA: one `qa_tasks_` schema on loopback PostgreSQL, twelve
/// seeded tasks, a Jira that lives in memory. No other service starts.
struct TasksSyntheticPreview: View {
    @State private var host: TasksHost?
    @State private var error: String?
    @State private var settings = false

    var body: some View {
        Group {
            if let host {
                WorkspaceSplitView(width: .constant(320), minimum: 280, maximum: 390, minimumDetail: 460) {
                    if let model = host.model {
                        TasksSidebarView(model: model).background { WorkspaceBackdrop(intensity: 0.55) }
                    }
                } detail: {
                    TasksDetailView(host: host)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        HStack {
                            Label("СИНТЕТИЧЕСКАЯ ПРОВЕРКА", systemImage: "testtube.2").font(.caption.bold())
                            Button("Настройки задач") { settings = true }.accessibilityIdentifier("tasks.qa.settings")
                        }
                    }
                }
                .sheet(isPresented: $settings) {
                    VStack {
                        if let model = host.model { TasksSettingsForm(model: model) }
                        Button("Готово") { settings = false }.padding()
                    }.makoshAppearance()
                }
                .environment(\.tasksHost, host)
                .environment(\.colorScheme, .dark)
            } else if let error {
                Text(error).padding(24).accessibilityIdentifier("tasks.qa.configurationRequired")
            } else {
                ProgressView("Проверка отдельной конфигурации QA «Задачи»…")
            }
        }
        .task {
            guard host == nil, error == nil else { return }
            let args = CommandLine.arguments
            do {
                let configuration = try await BackgroundWork.run {
                    guard let index = args.firstIndex(of: "--database-config"), args.indices.contains(index + 1) else {
                        throw TasksQAIsolation.Failure.invalidConfiguration
                    }
                    let file = URL(fileURLWithPath: args[index + 1])
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                        let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0
                    else { throw TasksQAIsolation.Failure.invalidConfiguration }
                    let value = try JSONDecoder().decode(ContactWorkspaceConfiguration.self, from: Data(contentsOf: file))
                    try TasksQAIsolation.validate(configuration: value, arguments: args)
                    return value
                }
                let jira = JiraSyntheticAdapter()
                let host = TasksHost(synthetic: jira)
                await host.start(configuration: configuration) { store in
                    try await TasksSyntheticSeed.seed(store: store)
                }
                if let service = host.service, let connection = try await service.store.connections().first {
                    try await service.save(connection, token: "qa-token")
                    await host.model?.syncNow()
                }
                self.host = host
            } catch {
                self.error = "QA «Задачи» требует --tasks-synthetic-preview и отдельную конфигурацию PostgreSQL со схемой qa_tasks_."
            }
        }
    }
}
#endif
