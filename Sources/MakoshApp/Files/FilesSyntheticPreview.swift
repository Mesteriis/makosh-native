#if DEBUG
import MakoshCore
import MakoshFiles
import SwiftUI

/// Isolated Files QA: `qa_files_` schemas on loopback PostgreSQL, six seeded
/// files, a Paperless that lives in memory. No other service starts.
struct FilesSyntheticPreview: View {
    @State private var host: FilesHost?
    @State private var error: String?
    @State private var settings = false

    var body: some View {
        Group {
            if let host {
                WorkspaceSplitView(width: .constant(320), minimum: 280, maximum: 390, minimumDetail: 460) {
                    FilesSidebarView(model: host.model, host: host).background { WorkspaceBackdrop(intensity: 0.55) }
                } detail: {
                    FilesDetailView(model: host.model, host: host)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        HStack {
                            Label("СИНТЕТИЧЕСКАЯ ПРОВЕРКА", systemImage: "testtube.2").font(.caption.bold())
                            Button("Настройки файлов") { settings = true }.accessibilityIdentifier("files.qa.settings")
                        }
                    }
                }
                .sheet(isPresented: $settings) {
                    VStack {
                        FilesSettingsForm(model: host.model)
                        Button("Готово") { settings = false }.padding()
                    }
                }
                .sheet(item: Binding(get: { host.pendingSend }, set: { host.pendingSend = $0 })) { request in
                    PaperlessSendSheet(model: host.model, request: request)
                }
                .modifier(
                    FileForwardColumn(host: host, destinations: { _ in [] }, perform: { _, _ in "В синтетической проверке адресатов нет." })
                )
                .onChange(of: host.pendingAsk?.id) { _, _ in
                    guard host.pendingAsk != nil else { return }
                    host.pendingAsk = nil
                    host.model.error = "ИИ в синтетической проверке «Файлов» не запускается; карточка файла проверяется в QA ИИ."
                }
                .environment(\.filesHost, host)
                .environment(\.colorScheme, .dark)
            } else if let error {
                Text(error).padding(24).accessibilityIdentifier("files.qa.configurationRequired")
            } else {
                ProgressView("Проверка отдельной конфигурации QA «Файлы»…")
            }
        }
        .task {
            guard host == nil, error == nil else { return }
            let args = CommandLine.arguments
            do {
                let configuration = try await BackgroundWork.run {
                    guard let index = args.firstIndex(of: "--database-config"), args.indices.contains(index + 1) else {
                        throw FilesQAIsolation.Failure.invalidConfiguration
                    }
                    let file = URL(fileURLWithPath: args[index + 1])
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                        let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0
                    else { throw FilesQAIsolation.Failure.invalidConfiguration }
                    let value = try JSONDecoder().decode(PersonWorkspaceConfiguration.self, from: Data(contentsOf: file))
                    try FilesQAIsolation.validate(configuration: value, arguments: args)
                    return value
                }
                let key: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x5f, count: 32) }
                try await BackgroundWork.run {
                    let store = try MessageArchiveStore(
                        connectionString: configuration.connectionString, schema: configuration.archiveSchema ?? configuration.schema,
                        keyProvider: key)
                    try FilesSyntheticSeed.seed(store)
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "makosh-files-qa-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let defaults = UserDefaults(suiteName: "org.makosh.files.qa.\(configuration.schema)") ?? .standard
                defaults.removePersistentDomain(forName: "org.makosh.files.qa.\(configuration.schema)")
                let host = FilesHost(
                    synthetic: directory.appendingPathComponent("submissions.json"), defaults: defaults,
                    paperless: PaperlessSyntheticService())
                host.start(configuration: configuration, resolver: nil, keyProvider: key)
                let connection = PaperlessConnection(
                    name: "Синтетический Paperless", baseURL: URL(string: "https://paperless.synthetic")!, defaultDocumentType: 2,
                    defaultTags: [1])
                try await host.model.save(.paperless(connection), token: "qa-token")
                await host.model.test(connection.id)
                await host.model.refresh()
                self.host = host
            } catch {
                self.error = "QA «Файлы» требует --files-synthetic-preview и отдельную конфигурацию PostgreSQL со схемой qa_files_."
            }
        }
    }
}
#endif
