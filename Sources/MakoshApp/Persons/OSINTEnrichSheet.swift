import MakoshCore
import MakoshOSINT
import SwiftUI

/// «Обогатить (OSINT)…»: which values leave the Mac and which sources the server asks.
struct OSINTEnrichSheet: View {
    let person: Person
    @ObservedObject var osint: OSINTWorkspaceModel
    let launched: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var inputs: [OSINTInput] = []
    @State private var chosenInputs: Set<OSINTInput> = []
    @State private var chosenEnrichers: Set<OSINTEnricher> = []
    @State private var loaded = false

    private var settings: OSINTSettings? { osint.snapshot?.settings }
    private var rows: [(enricher: OSINTEnricher, enabled: Bool, note: String?)] {
        OSINTDialogRules.availableEnrichers(
            selected: settings?.manualEnrichers ?? [], inputs: Array(chosenInputs), serverKeyNames: osint.snapshot?.serverKeyNames ?? [],
            serverEnricherNames: osint.snapshot?.serverEnricherNames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Обогатить «\(person.displayName)»").font(.headline)
            if !loaded {
                ProgressView().controlSize(.small)
            } else if inputs.isEmpty {
                Text("У персоны нет адресов, телефонов, username или имени, с которых можно начать.").foregroundStyle(.secondary)
            } else {
                Text("Что отправить").font(.callout.weight(.semibold))
                ForEach(inputs, id: \.self) { input in
                    Toggle(
                        "\(Self.typeTitle(input.type)): \(input.value)",
                        isOn: Binding(
                            get: { chosenInputs.contains(input) },
                            set: { on in if on { chosenInputs.insert(input) } else { chosenInputs.remove(input) } })
                    ).toggleStyle(.checkbox).accessibilityIdentifier("osint.input.\(input.value)")
                }
                Text("Источники").font(.callout.weight(.semibold))
                if rows.isEmpty { Text("Для выбранных значений нет включённых источников.").font(.caption).foregroundStyle(.secondary) }
                ForEach(rows, id: \.enricher) { row in
                    Toggle(
                        row.enricher.title + (row.note.map { " — \($0)" } ?? ""),
                        isOn: Binding(
                            get: { chosenEnrichers.contains(row.enricher) },
                            set: { on in if on { chosenEnrichers.insert(row.enricher) } else { chosenEnrichers.remove(row.enricher) } })
                    ).toggleStyle(.checkbox).disabled(!row.enabled).accessibilityIdentifier("osint.enricher.\(row.enricher.rawValue)")
                }
                Text(OSINTDialogRules.disclosure(host: settings?.host ?? "", enrichers: chosenEnrichers)).font(.caption)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Запустить") {
                    let chosen = chosenEnrichers.filter { enricher in rows.contains { $0.enricher == enricher && $0.enabled } }
                    let values = chosenInputs
                    _Concurrency.Task {
                        if await osint.enrich(personID: person.id, enrichers: chosen, inputs: Array(values)) { launched() }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(!OSINTDialogRules.canLaunch(inputs: chosenInputs, enrichers: enabledChosen))
                .accessibilityIdentifier("osint.launch")
            }
        }
        .padding(20).frame(width: 560)
        .task {
            inputs = await osint.inputs(personID: person.id)
            chosenInputs = Set(inputs)
            chosenEnrichers = Set(rows.filter(\.enabled).map(\.enricher))
            loaded = true
        }
    }

    private var enabledChosen: Set<OSINTEnricher> {
        chosenEnrichers.filter { enricher in rows.contains { $0.enricher == enricher && $0.enabled } }
    }

    static func typeTitle(_ type: FlowsintNodeType) -> String {
        switch type {
        case .email: "Адрес"
        case .phone: "Телефон"
        case .username: "Username"
        case .individual: "Имя"
        case .organization: "Организация"
        case .socialAccount: "Аккаунт"
        case .gravatar: "Аватар"
        case .breach: "Утечка"
        case .device: "Устройство"
        case .domain: "Домен"
        }
    }
}
