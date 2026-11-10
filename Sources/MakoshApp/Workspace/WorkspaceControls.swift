import SwiftUI

/// Frosted, tinted surfaces shared by chrome, forms and app-owned overlays.
struct WorkspaceSurface: View {
    var radius: CGFloat = WorkspaceStyle.controlRadius
    var elevated = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        ZStack {
            if !reduceTransparency { shape.fill(.ultraThinMaterial) }
            shape.fill(WorkspaceStyle.surface.opacity(reduceTransparency ? 1 : elevated ? 0.94 : 0.82))
            shape.fill(LinearGradient(colors: [WorkspaceStyle.highlight, .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay(shape.strokeBorder(WorkspaceStyle.border, lineWidth: 1))
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct WorkspaceButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, WorkspaceStyle.controlInset).padding(.vertical, 7)
            .frame(
                minHeight: controlSize == .mini || controlSize == .small
                    ? WorkspaceStyle.compactControlHeight
                    : controlSize == .large || controlSize == .extraLarge ? WorkspaceStyle.largeControlHeight : WorkspaceStyle.controlHeight
            )
            .foregroundStyle(configuration.role == .destructive ? Color.red : prominent ? Color.white : Color.primary)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius).fill(
                        WorkspaceStyle.accent.opacity(configuration.isPressed ? 0.65 : 0.85))
                } else {
                    WorkspaceSurface()
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius)
                    .fill(WorkspaceStyle.accent.opacity(configuration.isPressed ? 0.16 : 0))
            }
            .opacity(enabled ? 1 : WorkspaceStyle.disabledOpacity)
            .contentShape(RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius))
    }
}

struct WorkspaceTextFieldStyle: TextFieldStyle {
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .padding(.horizontal, WorkspaceStyle.controlInset).padding(.vertical, 7)
            .background { WorkspaceSurface() }
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius)
                    .strokeBorder(focused ? WorkspaceStyle.accent : .clear, lineWidth: 1.5)
            }
            .opacity(enabled ? 1 : WorkspaceStyle.disabledOpacity)
    }
}

/// Own section cards preserve the layout of each service row without reinterpreting its labels.
struct WorkspaceFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WorkspaceStyle.sectionGap) {
                ForEach(sections: configuration.content) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        if !section.header.isEmpty {
                            HStack {
                                ForEach(section.header) { $0 }
                                Spacer(minLength: 0)
                            }
                            .font(.headline).padding(.horizontal, 4)
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(section.content) { row in
                                row.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(WorkspaceStyle.cardInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background { WorkspaceSurface(radius: WorkspaceStyle.cardRadius) }
                        if !section.footer.isEmpty {
                            ForEach(section.footer) { $0 }
                                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                        }
                    }
                }
            }.padding(WorkspaceStyle.sectionGap).frame(maxWidth: .infinity, alignment: .leading)
        }
        .textFieldStyle(WorkspaceTextFieldStyle())
        .buttonStyle(WorkspaceButtonStyle())
        .toggleStyle(WorkspaceToggleStyle())
        .tint(WorkspaceStyle.accent)
    }
}

/// Branded segments keep public container tags and their existing bindings.
struct WorkspaceSegmentedPicker<Selection: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: Selection
    let content: Content
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, selection: Binding<Selection>, @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            segments
            ScrollView(.horizontal) { segments }.scrollIndicators(.hidden)
        }
        .frame(height: WorkspaceStyle.segmentHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityRepresentation { Picker(title, selection: $selection) { content }.pickerStyle(.segmented) }
    }

    private var segments: some View {
        Group(subviews: content) { children in
            HStack(spacing: 4) {
                ForEach(children.indices, id: \.self) { index in
                    let child = children[index]
                    if let value = child.containerValues.tag(for: Selection.self) {
                        Button {
                            selection = value
                        } label: {
                            child.lineLimit(1).fixedSize()
                                .font(.callout.weight(selection == value ? .semibold : .regular))
                                .padding(.horizontal, WorkspaceStyle.controlInset).padding(.vertical, 7)
                                .foregroundStyle(selection == value ? WorkspaceStyle.accent : .secondary)
                                .background(
                                    selection == value ? WorkspaceStyle.accent.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: WorkspaceStyle.controlRadius))
                        }.buttonStyle(.plain)
                            .accessibilityAddTraits(selection == value ? .isSelected : [])
                    }
                }
            }.padding(4).background { WorkspaceSurface() }
                .opacity(enabled ? 1 : WorkspaceStyle.disabledOpacity)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selection)
        }
    }
}

struct WorkspaceToggleStyle: ToggleStyle {
    var checkbox = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.labelsVisibility) private var labels

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                if checkbox { control(configuration) }
                if labels != .hidden { configuration.label }
                if !checkbox {
                    Spacer(minLength: 12)
                    control(configuration)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
            }
    }

    private func control(_ configuration: Configuration) -> some View {
        ZStack(alignment: checkbox ? .center : configuration.isOn ? .trailing : .leading) {
            RoundedRectangle(cornerRadius: checkbox ? 4 : 12)
                .fill(configuration.isOn ? WorkspaceStyle.accent : WorkspaceStyle.surface)
            RoundedRectangle(cornerRadius: checkbox ? 4 : 12)
                .strokeBorder(configuration.isOn ? WorkspaceStyle.accent : WorkspaceStyle.border, lineWidth: 1)
            if checkbox {
                if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
            } else {
                Circle().fill(configuration.isOn ? .white : WorkspaceStyle.accent.opacity(0.55)).padding(3).frame(width: 24)
            }
        }.frame(width: checkbox ? 18 : 40, height: checkbox ? 18 : 24)
            .opacity(enabled ? 1 : WorkspaceStyle.disabledOpacity)
    }

}

/// The integer steppers used by Makosh settings and time drafts.
struct WorkspaceStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    init(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 12)
            Button {
                value = max(range.lowerBound, value - step)
            } label: {
                Image(systemName: "minus").frame(width: 12, height: 12)
            }
            .disabled(value <= range.lowerBound).accessibilityLabel("Уменьшить: " + title)
            Button {
                value = min(range.upperBound, value + step)
            } label: {
                Image(systemName: "plus").frame(width: 12, height: 12)
            }
            .disabled(value >= range.upperBound).accessibilityLabel("Увеличить: " + title)
        }
        .accessibilityRepresentation { Stepper(title, value: $value, in: range, step: step) }
    }
}

/// TextEditor owns a separate scroll view; hide its background at the editor itself.
extension TextEditor {
    func workspaceEditorSurface() -> some View {
        scrollContentBackground(.hidden)
            .padding(WorkspaceStyle.controlInset)
            .background { WorkspaceSurface() }
    }
}
