import MakoshTasks
import SwiftUI

/// The reference's quick entry: committed tokens become pills inside the
/// field, completions drop down for the word being typed, Enter creates.
struct TaskQuickEntryField: View {
    @ObservedObject var model: TasksWorkspaceModel
    var focused: FocusState<Bool>.Binding
    @State private var highlighted = 0

    private var suggestions: [TaskQuickEntrySuggestion] { focused.wrappedValue ? model.quickEntrySuggestions : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                ForEach(Array(model.quickEntry.chips.enumerated()), id: \.offset) { index, chip in
                    TaskChipPill(kind: chip.kind, text: chip.raw) { model.quickEntry.remove(at: index) }
                }
                TextField(
                    model.quickEntry.isEmpty ? "Новая задача… (@список #тег /персона !1 ^срок *повтор >>цепочка ~код)" : "",
                    text: Binding(
                        get: { model.quickEntry.text },
                        set: { value in
                            model.quickEntry.typed(value, extractURLs: model.storedPreferences.extractURLs)
                            highlighted = 0
                        })
                )
                .textFieldStyle(.plain).font(.body.monospaced()).focused(focused)
                .onSubmit {
                    if !suggestions.isEmpty, isTypingToken {
                        accept(suggestions[min(highlighted, suggestions.count - 1)])
                    } else {
                        _Concurrency.Task { await model.create() }
                    }
                }
                .onKeyPress(.downArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    highlighted = min(highlighted + 1, suggestions.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard !suggestions.isEmpty else { return .ignored }
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard !suggestions.isEmpty else { return .ignored }
                    accept(suggestions[min(highlighted, suggestions.count - 1)])
                    return .handled
                }
                .onKeyPress(.delete) {
                    guard model.quickEntry.text.isEmpty else { return .ignored }
                    return model.quickEntry.backspaceOnEmpty() ? .handled : .ignored
                }
                .onKeyPress(.escape) {
                    focused.wrappedValue = false
                    return .handled
                }
                .accessibilityIdentifier("tasks.quickEntry")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused.wrappedValue ? TaskStyle.selection : Color.white.opacity(0.1)))
            .contentShape(Rectangle())
            .onTapGesture { focused.wrappedValue = true }
            .background { Button("") { focused.wrappedValue = true }.keyboardShortcut("n", modifiers: .command).hidden() }
        }
        .overlay(alignment: .topLeading) {
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.prefix(8).enumerated()), id: \.element.id) { index, suggestion in
                        Button {
                            accept(suggestion)
                        } label: {
                            HStack(spacing: 8) {
                                TaskChipPill(kind: suggestion.kind, text: suggestion.label, onRemove: nil)
                                if let detail = suggestion.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(index == highlighted ? Color.white.opacity(0.1) : Color.clear)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.12)))
                .shadow(radius: 8).offset(y: 42).zIndex(10)
                .accessibilityIdentifier("tasks.quickEntry.suggestions")
            }
        }
        .zIndex(10)
    }

    private var isTypingToken: Bool {
        guard let last = model.quickEntry.text.split(separator: " ", omittingEmptySubsequences: false).last else { return false }
        return last.hasPrefix(">>") || "@#/!^*".contains(last.first ?? " ")
    }

    private func accept(_ suggestion: TaskQuickEntrySuggestion) {
        model.quickEntry.accept(suggestion)
        highlighted = 0
    }
}

/// A token pill: the reference's colours per token kind, with an optional «×».
struct TaskChipPill: View {
    let kind: TaskQuickEntry.Kind
    let text: String
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Text(text).font(.caption.monospaced())
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain).opacity(
                    0.65)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(color.opacity(0.18), in: Capsule()).overlay(Capsule().stroke(color.opacity(0.45))).foregroundStyle(color)
    }

    private var color: Color {
        switch kind {
        case .text: .primary
        case .list: Color(red: 0.204, green: 0.827, blue: 0.6)
        case .tag: TaskStyle.tag
        case .persona: TaskStyle.persona
        case .priority: Color(red: 0.984, green: 0.573, blue: 0.235)
        case .due: TaskStyle.due
        case .recurrence: Color(red: 0.176, green: 0.831, blue: 0.749)
        case .flow: TaskStyle.flow
        case .dependency: Color(red: 0.98, green: 0.8, blue: 0.082)
        case .url: Color(red: 0.376, green: 0.647, blue: 0.98)
        }
    }
}

/// The tokens the parser found, under the field; unresolved ones say why.
struct TaskQuickEntryPreview: View {
    let entry: TaskQuickEntry

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<entry.tokens.count, id: \.self) { index in
                let token = entry.tokens[index]
                TaskChipPill(kind: token.kind, text: token.text, onRemove: nil).opacity(token.resolved ? 1 : 0.5)
                    .overlay(alignment: .topTrailing) {
                        if !token.resolved {
                            Image(systemName: "questionmark.circle.fill").font(.system(size: 9)).foregroundStyle(.orange).offset(
                                x: 3, y: -4)
                        }
                    }
                    .help(hint(token))
            }
            Spacer()
        }.accessibilityIdentifier("tasks.quickEntry.preview")
    }

    private func hint(_ token: TaskQuickEntry.Token) -> String {
        guard !token.resolved else { return "" }
        switch token.kind {
        case .due: return "Дата не распознана — останется в названии."
        case .dependency: return "Задача не найдена — останется в названии."
        case .recurrence: return "Повтор не распознан — останется в названии."
        default: return ""
        }
    }
}
