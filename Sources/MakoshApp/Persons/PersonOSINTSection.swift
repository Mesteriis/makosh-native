import AppKit
import MakoshCore
import MakoshOSINT
import SwiftUI

/// The «OSINT» part of a person card: the last run, the launch button, the graph link and the grouped findings.
struct PersonOSINTSection: View {
    let person: Person
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var osint: OSINTWorkspaceModel
    let merge: () -> Void
    @State private var enriching = false
    @State private var confirmDelete = false
    @State private var duplicateOf: UUID?

    private var settings: OSINTSettings? { osint.snapshot?.settings }
    private var run: OSINTRun? { osint.snapshot?.lastRuns[person.id] }
    private var openAttempts: [OSINTAttempt] { (osint.snapshot?.openAttempts ?? []).filter { $0.personID == person.id } }
    private var items: [OSINTCardItem] { OSINTCardGrouping.items(for: person) }
    private var disabledReason: String? {
        settings.map { OSINTDialogRules.disabledReason(settings: $0, person: person) } ?? "Модуль не открыт"
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(Self.statusText(run: run, attempts: openAttempts)).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("person.osint.status")
                    Spacer()
                    if let unknown = openAttempts.first(where: { $0.state == .unknown }) {
                        Button("Проверить") { _Concurrency.Task { await osint.settle(attemptID: unknown.id) } }
                        Button("Отказаться") { _Concurrency.Task { await osint.dismiss(attemptID: unknown.id) } }
                    }
                    Button("Обогатить (OSINT)…") { enriching = true }
                        .disabled(disabledReason != nil || !workspace.canWrite || osint.busy)
                        .help(disabledReason ?? "Отправить значения персоны на ваш сервер flowsint")
                        .accessibilityIdentifier("person.osint.enrich")
                    if osint.snapshot?.sketches[person.id] != nil {
                        Button("Открыть граф") {
                            _Concurrency.Task { if let url = await osint.graphURL(personID: person.id) { NSWorkspace.shared.open(url) } }
                        }.accessibilityIdentifier("person.osint.graph")
                        Menu {
                            Button("Удалить данные OSINT…", role: .destructive) { confirmDelete = true }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }.menuStyle(.borderlessButton).fixedSize().disabled(!workspace.canWrite)
                    }
                }
                if let run, run.state == .failed, let failure = run.failure {
                    Text(OSINTWorkspaceModel.describe(failure)).font(.caption).foregroundStyle(.orange).fixedSize(
                        horizontal: false, vertical: true)
                }
                if run?.truncated == true {
                    Text("Показаны первые находки; остальные есть в графе на сервере.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(OSINTCardGroup.allCases, id: \.self) { group in
                    let rows = items.filter { $0.group == group }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(rows) { item in itemRow(item) }
                        }
                    }
                }
                if items.isEmpty, run == nil {
                    Text(
                        "Находок пока нет. Обогащение отправляет значения на ваш сервер и дальше в сторонние сервисы — только по вашей команде или по флагу книги."
                    )
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        } label: {
            Label("OSINT", systemImage: "network")
        }
        .accessibilityIdentifier("person.osint")
        .onChange(of: osint.runsSettled) { _, _ in _Concurrency.Task { await workspace.reload() } }
        .sheet(isPresented: $enriching) {
            OSINTEnrichSheet(person: person, osint: osint) { _Concurrency.Task { await workspace.reload() } }.makoshAppearance()
        }
        .confirmationDialog("Удалить данные OSINT этой персоны?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                _Concurrency.Task {
                    await osint.deleteOSINTData(personID: person.id)
                    await workspace.reload()
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Схема на сервере и непринятые находки будут удалены; принятые значения и журнал попыток останутся.")
        }
        .alert(
            "Совпадает с персоной «\(duplicateName)»",
            isPresented: Binding(get: { duplicateOf != nil }, set: { if !$0 { duplicateOf = nil } })
        ) {
            Button("Склеить с…") {
                duplicateOf = nil
                merge()
            }
            Button("Отмена", role: .cancel) { duplicateOf = nil }
        } message: {
            Text("Это значение уже есть у другой персоны. Makosh не принимает его сам: склейте персоны или оставьте предложение.")
        }
    }

    private var duplicateName: String { duplicateOf.flatMap { id in workspace.persons.first { $0.id == id }?.displayName } ?? "" }

    private func itemRow(_ item: OSINTCardItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(item.title): ").font(.callout)
                + Text(item.value).font(.callout).foregroundStyle(item.status == .proposed ? .secondary : .primary)
            if item.formerlyRemoved { Text("ранее убрано").font(.caption).foregroundStyle(.orange) }
            if item.status == .rejected { Text("отклонено").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if item.status == .proposed {
                Button("Принять") {
                    _Concurrency.Task {
                        let outcome = await osint.accept(personID: person.id, observationID: item.id)
                        if case .duplicateOf(let other) = outcome { duplicateOf = other }
                        await workspace.reload()
                    }
                }.disabled(!workspace.canWrite).accessibilityIdentifier("person.osint.accept.\(item.id)")
                Button("Отклонить") {
                    _Concurrency.Task {
                        await osint.reject(personID: person.id, observationID: item.id)
                        await workspace.reload()
                    }
                }.disabled(!workspace.canWrite).accessibilityIdentifier("person.osint.reject.\(item.id)")
            }
        }.textSelection(.enabled)
    }

    static func statusText(run: OSINTRun?, attempts: [OSINTAttempt]) -> String {
        if attempts.contains(where: { $0.state == .unknown }) { return "Есть попытка без ответа сервера" }
        guard let run else { return "Не обогащалась" }
        switch run.state {
        case .queued: return "В очереди на обогащение"
        case .running: return "Идёт запуск…"
        case .unknown: return "Исход запуска неизвестен"
        case .failed: return "Ошибка: \(run.failure?.code ?? "unknown")"
        case .completed:
            let date = (run.finishedAt ?? run.createdAt).formatted(date: .abbreviated, time: .shortened)
            return "Обогащена \(date), находок: \(run.found)"
        }
    }
}
