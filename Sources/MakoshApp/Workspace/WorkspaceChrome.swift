import SwiftUI

/// Shared native shell. The rail remains mounted while its content changes.
struct WorkspaceChrome<Content: View>: View {
    @Binding var destination: WorkspaceDestination?
    var allowed: [WorkspaceDestination] = WorkspaceDestination.allCases
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 4) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(WorkspaceDestination.allCases.filter { $0 != .settings }) { item in
                            entry(item).disabled(!allowed.contains(item)).opacity(allowed.contains(item) ? 1 : 0.3)
                        }
                    }
                }.scrollIndicators(.hidden)
                if allowed.contains(.settings) { entry(.settings) }
            }
            .padding(.horizontal, WorkspaceStyle.railInset).padding(.vertical, 8)
            .frame(width: WorkspaceStyle.railWidth)
            .background { WorkspaceSurface(radius: 0) }
            Divider()
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(WorkspaceStyle.base)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(destination?.rawValue ?? "Макош").font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).padding(.leading, WorkspaceStyle.controlInset)
                    .frame(width: WorkspaceStyle.sectionTitleWidth, alignment: .leading)
                    .accessibilityIdentifier("workspace.sectionTitle")
            }.sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackground(WorkspaceStyle.base, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbarColorScheme(.dark, for: .windowToolbar)
    }

    private func entry(_ item: WorkspaceDestination) -> some View {
        Button {
            destination = item
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: WorkspaceStyle.railIconSize, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(destination == item ? WorkspaceStyle.accent : .primary)
                .frame(width: WorkspaceStyle.railButtonSize, height: WorkspaceStyle.railButtonSize)
                .background(
                    destination == item ? WorkspaceStyle.accent.opacity(0.20) : .clear,
                    in: RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(item.rawValue)
        .accessibilityLabel(item.rawValue)
        .accessibilityValue(destination == item ? "Выбрано" : "")
        .accessibilityAddTraits(destination == item ? [.isSelected] : [])
        .accessibilityIdentifier("workspace.section.\(item.symbol)")
    }
}

struct WorkspaceSettingsPage<Content: View>: View {
    @Binding var category: String
    var allowed: [WorkspaceSettingsCategory] = WorkspaceSettingsCategory.allCases
    @ViewBuilder let content: (WorkspaceSettingsCategory) -> Content

    @FocusState private var focusedCategory: WorkspaceSettingsCategory?
    private var selectedCategory: WorkspaceSettingsCategory? { WorkspaceSettingsCategory.resolve(category, allowed: allowed) }
    private func moveCategory(from item: WorkspaceSettingsCategory, by offset: Int) {
        guard let index = allowed.firstIndex(of: item), allowed.indices.contains(index + offset) else { return }
        let next = allowed[index + offset]
        category = next.rawValue
        focusedCategory = next
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(allowed) { item in
                        Button {
                            category = item.rawValue
                            focusedCategory = item
                        } label: {
                            Label(item.destination.rawValue, systemImage: item.destination.symbol)
                                .symbolRenderingMode(.monochrome)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 12)
                                .foregroundStyle(selectedCategory == item ? WorkspaceStyle.accent : .primary)
                                .background(
                                    selectedCategory == item ? WorkspaceStyle.accent.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius))
                        }.buttonStyle(.plain)
                            .focusable()
                            .focused($focusedCategory, equals: item)
                            .accessibilityAddTraits(selectedCategory == item ? .isSelected : [])
                            .accessibilityIdentifier("settings.category.\(item.rawValue)")
                            .onKeyPress(.upArrow) {
                                moveCategory(from: item, by: -1)
                                return .handled
                            }
                            .onKeyPress(.downArrow) {
                                moveCategory(from: item, by: 1)
                                return .handled
                            }
                    }
                }.padding(10)
            }
            .frame(width: WorkspaceStyle.settingsSidebarWidth)
            .background { WorkspaceSurface(radius: 0) }
            Divider()
            if let selected = WorkspaceSettingsCategory.resolve(category, allowed: allowed) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(selected.destination.rawValue).font(.title2.bold()).padding(.horizontal, 24).padding(.top, 20)
                    content(selected).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityIdentifier("workspace.settings")
    }
}

/// One tab strip for settings forms; selection belongs to each existing form.
struct WorkspaceSettingsTabs: View {
    let titles: [String]
    @Binding var selection: String
    var body: some View {
        WorkspaceSegmentedPicker("Раздел настроек", selection: $selection) {
            ForEach(titles, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().padding(.horizontal, 20)
        .accessibilityIdentifier("settings.tabs")
    }
}

#if DEBUG
/// Uses the production chrome and settings page while retaining each preview's isolated service host.
struct SyntheticWorkspaceFrame<Content: View, Settings: View>: View {
    let service: WorkspaceSettingsCategory
    @ViewBuilder let content: () -> Content
    @ViewBuilder let settings: () -> Settings
    @State private var selected: WorkspaceDestination?
    @State private var category = ""
    @EnvironmentObject private var navigation: WorkspaceNavigation

    var body: some View {
        WorkspaceChrome(
            destination: Binding(get: { selected ?? service.destination }, set: { selected = $0 }),
            allowed: [service.destination, .settings]
        ) {
            if selected == .settings {
                WorkspaceSettingsPage(category: $category, allowed: [service]) { _ in settings() }
            } else {
                content()
            }
        }
        .onReceive(navigation.$settingsRequest) { if $0 != nil { selected = .settings } }
        .onReceive(navigation.$destinationRequest) { if $0 == service.destination { selected = $0 } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Text("Синтетические данные").font(.caption).foregroundStyle(.secondary)
            }.sharedBackgroundVisibility(.hidden)
        }
    }
}
#endif
