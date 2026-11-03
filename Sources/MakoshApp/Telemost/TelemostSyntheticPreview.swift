#if DEBUG
import SwiftUI
import MakoshCore
import MakoshTelemost

struct TelemostSyntheticPreview: View {
    @State private var model: TelemostWorkspaceModel?
    @State private var dossier: WorkspaceModel?
    @State private var largeText = false
    @State private var error: String?
    var body: some View {
        Group {
            if let model, let dossier {
                WorkspaceView(syntheticTelemost: model, dossier: dossier)
                    .dynamicTypeSize(largeText ? .accessibility1 : .large)
                    .toolbar { ToolbarItem(placement: .primaryAction) { Toggle("Крупный текст", isOn: $largeText).toggleStyle(.button).accessibilityIdentifier("telemost.qa.largeText") } }
            }
            else if let error { Text(error).padding(24).accessibilityIdentifier("telemost.qa.configurationRequired") }
            else { ProgressView("Проверка отдельной конфигурации Телемоста QA…") }
        }.task {
            guard model == nil, error == nil else { return }
            let args = CommandLine.arguments
            do {
                let configuration = try await BackgroundWork.run {
                    guard let index = args.firstIndex(of: "--database-config"), args.indices.contains(index + 1) else { throw TelemostFailure.invalidConfiguration }
                    let file = URL(fileURLWithPath: args[index + 1])
                    guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path), let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else { throw TelemostFailure.invalidConfiguration }
                    let value = try JSONDecoder().decode(ContactWorkspaceConfiguration.self, from: Data(contentsOf: file))
                    guard TelemostSyntheticLaunchPolicy.admits(arguments: args, configuration: value) else { throw TelemostFailure.invalidConfiguration }; return value
                }
                let dossier = WorkspaceModel(requireExplicitDatabaseConfiguration: true, syntheticSchemaPrefix: "qa_telemost_")
                await dossier.load()
                guard dossier.ready else { throw TelemostFailure.storage }
                if dossier.contacts.isEmpty {
                    _ = try await dossier.dossierWorker.apply(.save(draft: .init(displayName: "Тестовый контакт Телемоста", organization: "Синтетическая команда"), id: nil))
                    _ = await dossier.reload()
                }
                let service = try await TelemostWorker.synthetic(configuration: configuration, arguments: args, contacts: dossier.dossierWorker)
                self.dossier = dossier
                self.model = TelemostWorkspaceModel(service: service, synthetic: true, opener: { _ in true })
            } catch { self.error = "Телемост QA требует явную локальную конфигурацию и обе схемы qa_telemost_. Ключи, провайдер и остальные сервисы не запускаются." }
        }
    }
}
#endif
