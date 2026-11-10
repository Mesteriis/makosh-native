#if DEBUG
import MakoshCore
import MakoshOSINT
import MakoshPersons
import SwiftUI

/// Isolated Persons QA: one `qa_persons_` schema on loopback PostgreSQL, four synthetic books and
/// the seeded letters, contacts and attempts, all in memory. No other service starts.
struct PersonsSyntheticPreview: View {
    private static let books = PersonsSyntheticSeed.books()
    private static let flowsint = FlowsintSynthetic(findings: OSINTSyntheticSeed.findings(), installed: false)
    @StateObject private var workspace = WorkspaceModel(
        requireExplicitDatabaseConfiguration: true, syntheticSchemaPrefix: PersonsQAIsolation.schemaPrefix)
    @StateObject private var host = PersonsHost(synthetic: PersonsSyntheticPreview.books, osint: PersonsSyntheticPreview.flowsint)
    @State private var sshFixture: OSINTSyntheticSSHServer?
    @StateObject private var ai = AIHost()
    @State private var ready = false
    @State private var error: String?
    @State private var editor: PersonsPreviewEditor?

    var body: some View {
        Group {
            if ready {
                SyntheticWorkspaceFrame(service: .persons) {
                    WorkspaceSplitView(width: .constant(320), minimum: 280, maximum: 390, minimumDetail: 640) {
                        PersonsSidebarView(
                            host: host, workspace: workspace,
                            newPerson: { kind in editor = PersonsPreviewEditor(contact: nil, kind: kind) },
                            openImport: {}, openReview: {}
                        ).background { WorkspaceBackdrop(intensity: 0.55) }
                    } detail: {
                        if let contact = workspace.selected {
                            PersonCardView(contact: contact, model: workspace, host: host) {
                                editor = PersonsPreviewEditor(contact: contact, kind: contact.kind)
                            }
                        } else {
                            ContentUnavailableView(
                                "Всё о человеке — рядом", systemImage: "person.text.rectangle",
                                description: Text("Выберите персону, чтобы открыть досье, книги, заметки и источники."))
                        }
                    }
                } settings: {
                    if let model = host.model { PersonsSettingsForm(model: model, host: host) }
                }
                .sheet(item: $editor) { selection in
                    PersonEditor(contact: selection.contact, kind: selection.kind, model: workspace).makoshAppearance()
                }
                .environmentObject(host).environment(\.personsHost, host).environmentObject(ai)
                .environment(\.colorScheme, .dark)
            } else if let error {
                Text(error).padding(24).accessibilityIdentifier("persons.qa.configurationRequired")
            } else {
                ProgressView("Проверка отдельной конфигурации QA «Персоны»…")
            }
        }
        .task {
            guard !ready, error == nil else { return }
            let args = CommandLine.arguments
            do {
                let configuration = try await BackgroundWork.run {
                    guard let index = args.firstIndex(of: "--database-config"), args.indices.contains(index + 1) else {
                        throw PersonsQAIsolation.Failure.invalidConfiguration
                    }
                    let file = URL(fileURLWithPath: args[index + 1])
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                        let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0
                    else { throw PersonsQAIsolation.Failure.invalidConfiguration }
                    let value = try JSONDecoder().decode(PersonWorkspaceConfiguration.self, from: Data(contentsOf: file))
                    try PersonsQAIsolation.validate(configuration: value, arguments: args)
                    return value
                }
                await workspace.load()
                guard workspace.ready, workspace.mailConfiguration?.schema == configuration.schema else {
                    throw PersonsQAIsolation.Failure.invalidConfiguration
                }
                let persons = try await BackgroundWork.run {
                    try PersonStore(connectionString: configuration.connectionString, schema: configuration.schema)
                }
                await host.configure(configuration: configuration, worker: workspace.dossierWorker) { service in
                    try await PersonsSyntheticSeed.seed(service: service, persons: persons, books: Self.books)
                    await service.settled()
                }
                guard host.failure == nil, let osint = host.osint else { throw PersonsQAIsolation.Failure.invalidConfiguration }
                // The OSINT fixture: a loopback SSH server scripted like LXC 164 and the synthetic flowsint behind it.
                let (server, _) = OSINTSyntheticSeed.scriptedServer(synthetic: Self.flowsint)
                let endpoint = try await server.start()
                sshFixture = server
                let people = try await BackgroundWork.run { try persons.persons() }
                let anna = people.first { $0.emails.contains(OSINTSyntheticSeed.annaEmail) }?.id
                let boris = people.first { $0.emails.contains("boris@sidorov.ru") }?.id
                guard let anna else { throw PersonsQAIsolation.Failure.invalidConfiguration }
                try await OSINTSyntheticSeed.seed(
                    service: osint, synthetic: Self.flowsint, persons: persons, annaID: anna, borisID: boris, host: endpoint.host,
                    port: endpoint.port)
                try OSINTQAIsolation.validate(settings: await osint.settings(), synthetic: true)
                await host.osintModel?.load()
                await workspace.reload()
                ready = true
            } catch {
                // The QA log (stderr) names the refusing check; the window keeps the generic text. These errors carry no secrets.
                FileHandle.standardError.write(Data("persons QA refused: \(String(describing: error))\n".utf8))
                self.error = "QA «Персоны» требует --persons-synthetic-preview и отдельную конфигурацию PostgreSQL со схемой qa_persons_."
            }
        }
    }
}

private struct PersonsPreviewEditor: Identifiable {
    let id = UUID()
    let contact: Person?
    let kind: PersonKind
}
#endif
