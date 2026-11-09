import MakoshCore
import MakoshPersons
import SwiftUI
import UniformTypeIdentifiers

/// The section's left column: organizations that open into their people, «Без организации»
/// at the bottom, a flag filter, a search field, and the duplicates and books sheets.
struct PersonsSidebarView: View {
    @ObservedObject var host: PersonsHost
    @ObservedObject var workspace: WorkspaceModel
    var newPerson: (PersonKind) -> Void
    var openImport: () -> Void
    var openReview: () -> Void
    @State private var search = ""
    @State private var books = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let model = host.model {
                PersonsSidebarBody(model: model, workspace: workspace, search: $search, showBooks: $books)
            } else if let failure = host.failure {
                Text(failure).foregroundStyle(.secondary).padding(20)
                Spacer()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $books) {
            if let model = host.model { PersonsBooksSheet(model: model).makoshAppearance() }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Персоны").font(.title2.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Человек") { newPerson(.person) }.accessibilityIdentifier("persons.create.person")
                Button("Организация") { newPerson(.organization) }.accessibilityIdentifier("persons.create.organization")
                Divider()
                Button("Импортировать JSON…", action: openImport).accessibilityIdentifier("persons.import")
            } label: {
                Image(systemName: "plus")
            }.menuStyle(.borderlessButton).fixedSize().help("Новая персона").accessibilityIdentifier("persons.create").disabled(
                !workspace.canWrite)
        }.padding(20)
    }

    private var subtitle: String {
        let count = workspace.persons.filter { $0.kind == .person }.count
        let organizations = workspace.persons.count - count
        return "\(count) в вашей картотеке" + (organizations > 0 ? " · организаций: \(organizations)" : "")
    }
}

private struct PersonsSidebarBody: View {
    @ObservedObject var model: PersonsWorkspaceModel
    @ObservedObject var workspace: WorkspaceModel
    @Binding var search: String
    @Binding var showBooks: Bool
    @State private var review = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker(
                    "Показывать",
                    selection: Binding(get: { model.filter == .addressBook }, set: { model.setFilter($0 ? .addressBook : .all) })
                ) {
                    Text("Все").tag(false)
                    Text("Адресная книга").tag(true)
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("persons.scope")
                Menu {
                    ForEach(PersonsFilter.allCases, id: \.self) { filter in
                        Button {
                            model.setFilter(filter)
                        } label: {
                            if model.filter == filter { Label(filter.title, systemImage: "checkmark") } else { Text(filter.title) }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }.menuStyle(.borderlessButton).fixedSize().help("Фильтр").accessibilityIdentifier("persons.filter")
            }.padding(.horizontal, 16)
            TextField("Имя, компания, почта, телефон", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(
                .vertical, 10
            ).accessibilityIdentifier("persons.search")
                .onChange(of: search) { _, value in
                    model.setSearch(value)
                    Task { await model.refresh() }
                }
            Divider()
            if model.tree.isEmpty {
                ContentUnavailableView(
                    "Пока нет персон", systemImage: "person.crop.rectangle.stack",
                    description: Text("Создайте персону, импортируйте JSON или подключите учётные записи в Настройках → Персоны.")
                ).frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                List(selection: $workspace.selectedID) {
                    ForEach(model.tree) { node in
                        switch node.kind {
                        case .organization(let id, let count): organizationRow(node, id: id, count: count)
                        case .section(let title):
                            Section(title) { ForEach(node.children) { child in personRow(child) } }
                        case .person: personRow(node)
                        }
                    }
                }.listStyle(.inset).scrollContentBackground(.hidden)
            }
            Divider()
            VStack(spacing: 10) {
                Button {
                    review = true
                } label: {
                    Label("Дубли · \(workspace.duplicates.count)", systemImage: "person.2.badge.gearshape").frame(maxWidth: .infinity)
                }.accessibilityIdentifier("persons.duplicates").disabled(!workspace.canWrite)
                Button {
                    showBooks = true
                } label: {
                    Label(booksTitle, systemImage: "books.vertical").frame(maxWidth: .infinity)
                }.accessibilityIdentifier("persons.books")
            }.padding(16)
        }
        .sheet(isPresented: $review) { MergeReviewView(model: workspace, persons: model).makoshAppearance() }
        .onChange(of: workspace.persons) { _, _ in Task { await model.refresh() } }
        .onChange(of: workspace.memberships) { _, _ in Task { await model.refresh() } }
    }

    private var booksTitle: String {
        let books = model.snapshot?.books.filter(\.kind.isBook) ?? []
        let open = model.snapshot?.openAttempts.count ?? 0
        return "Книги · \(books.count)" + (open > 0 ? " · ⟳ \(open)" : "")
    }

    @ViewBuilder private func organizationRow(_ node: PersonsTreeNode, id: UUID, count: Int) -> some View {
        let organization = workspace.persons.first { $0.id == id }
        HStack(spacing: 10) {
            Button {
                model.toggleExpanded(organizationID: id)
            } label: {
                Image(systemName: model.isExpanded(id) ? "chevron.down" : "chevron.right").font(.caption).frame(width: 12)
            }.buttonStyle(.plain).accessibilityIdentifier("persons.expand.\(id)")
            Image(systemName: "building.2").foregroundStyle(WorkspaceStyle.accent).frame(width: 24)
            Text(organization?.displayName ?? "Организация").font(.headline).lineLimit(1)
            Spacer()
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
            if organization?.addressBook == true { PersonsFlagBadge() }
        }
        .padding(.vertical, 6).tag(id).accessibilityIdentifier("person.row.\(id)")
        .dropDestination(for: String.self) { items, _ in
            guard let text = items.first, let personID = UUID(uuidString: text) else { return false }
            Task { _ = await workspace.addToOrganization(personID: personID, organizationID: id) }
            return true
        }
        if model.isExpanded(id) {
            ForEach(node.children) { child in personRow(child).padding(.leading, 22) }
        }
    }

    private func personRow(_ node: PersonsTreeNode) -> some View {
        Group {
            if case .person(let summary) = node.kind {
                HStack(spacing: 12) {
                    // Only the avatar starts a drag: a draggable row swallows the click that should select it.
                    PersonsAvatar(name: summary.displayName).draggable(summary.id.uuidString)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(summary.displayName).font(.headline).lineLimit(1)
                        Text(
                            summary.organization.isEmpty
                                ? (summary.firstEmail ?? summary.firstPhone ?? "Личная персона") : summary.organization
                        )
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if node.suggested { Image(systemName: "sparkles").foregroundStyle(.secondary).help("Предложено Makosh") }
                    if node.blocked {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Не ушла в одну из книг")
                    }
                    if summary.addressBook { PersonsFlagBadge() }
                }
                .padding(.vertical, 6).tag(summary.id).accessibilityIdentifier("person.row.\(summary.id)")
            }
        }
    }
}

struct PersonsFlagBadge: View {
    var body: some View {
        Text("книга").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
    }
}

struct PersonsAvatar: View {
    let name: String
    var size: CGFloat = 36
    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()).font(
            .system(size: size * 0.36, weight: .semibold)
        )
        .frame(width: size, height: size).foregroundStyle(WorkspaceStyle.accent).background(
            WorkspaceStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3))
    }
}
