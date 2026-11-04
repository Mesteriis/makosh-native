#if DEBUG
import MakoshAI
import MakoshCore
import SwiftUI

/// Isolated AI QA: `qa_ai_` schemas on loopback PostgreSQL, an offline
/// provider, an in-memory token store and a fixed synthetic vault key.
/// No other service starts.
struct AISyntheticPreview: View {
    @State private var host: AIHost?
    @State private var error: String?
    @State private var settings = false

    var body: some View {
        Group {
            if let host {
                WorkspaceSplitView(width: .constant(320), minimum: 280, maximum: 390, minimumDetail: 460) {
                    AIConversationListView(model: host.workspace, synthetic: true).background { WorkspaceBackdrop(intensity: 0.55) }
                } detail: {
                    AIConversationView(model: host.workspace)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Настройки ИИ") { settings = true }.accessibilityIdentifier("ai.qa.settings")
                    }
                }
                .sheet(isPresented: $settings) {
                    VStack {
                        AISettingsForm(model: host.settings)
                        AIIndexSection().environmentObject(host)
                        Button("Готово") {
                            settings = false
                            Task { await host.workspace.reload() }
                        }.padding()
                    }
                }
                .environment(\.colorScheme, .dark)
            } else if let error {
                Text(error).padding(24).accessibilityIdentifier("ai.qa.configurationRequired")
            } else {
                ProgressView("Проверка отдельной конфигурации ИИ QA…")
            }
        }
        .task {
            guard host == nil, error == nil else { return }
            let args = CommandLine.arguments
            do {
                let configuration = try await BackgroundWork.run {
                    guard let index = args.firstIndex(of: "--database-config"), args.indices.contains(index + 1) else {
                        throw AIFailure.invalidConfiguration
                    }
                    let file = URL(fileURLWithPath: args[index + 1])
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                        let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0
                    else { throw AIFailure.invalidConfiguration }
                    let value = try JSONDecoder().decode(ContactWorkspaceConfiguration.self, from: Data(contentsOf: file))
                    try AIQAIsolation.validate(configuration: value, arguments: args)
                    return value
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-ai-qa", isDirectory: true)
                let worker = AIWorker(
                    repository: AIRepository(keyProvider: { _, _ in Data(repeating: 0x5a, count: 32) }), client: AISyntheticService(),
                    vault: AIMemoryTokenVault(), images: AIImageStore(s3: nil, localDirectory: directory))
                let key: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x5a, count: 32) }
                // Seed a synthetic archive conversation that is open to the AI.
                try await BackgroundWork.run {
                    let store = try MessageArchiveStore(
                        connectionString: configuration.connectionString, schema: configuration.archiveSchema ?? configuration.schema,
                        keyProvider: key)
                    try AISyntheticSeed.seed(store)
                }
                let host = AIHost(worker: worker, synthetic: true)
                await host.start(configuration: configuration, contacts: nil, keyProvider: key, mail: false)
                if host.settings.connections.isEmpty {
                    let connection = AIConnection(name: "Синтетический сервер", baseURL: URL(string: "http://127.0.0.1:9/v1")!)
                    await host.settings.save(connection, token: nil)
                    await host.settings.test(connection.id)
                    await host.settings.assign(.chat, connectionID: connection.id, model: "synthetic-chat")
                    await host.settings.assign(.embeddings, connectionID: connection.id, model: "synthetic-embed")
                    await host.settings.assign(.images, connectionID: connection.id, model: "synthetic-image")
                    await host.settings.assign(.transcription, connectionID: connection.id, model: "synthetic-transcribe")
                }
                await host.indexNow()
                await host.workspace.reload()
                self.host = host
            } catch {
                self.error = "ИИ QA требует --ai-synthetic-preview и отдельную конфигурацию PostgreSQL со схемой qa_ai_."
            }
        }
    }
}
#endif
