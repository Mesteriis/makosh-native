import MakoshAI
import MakoshCore
import SwiftUI

/// The row of attached sources above the composer: what will be sent, its
/// period and counts, and a cross to remove it.
struct AIContextCardsView: View {
    @ObservedObject var model: AIWorkspaceModel
    let open: (AIContextCard) -> Void

    var body: some View {
        if !model.cards.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.cards) { card in
                        AIContextCardChip(card: card, model: model, open: open)
                    }
                }.padding(.horizontal, 12).padding(.top, 8)
            }
            .accessibilityIdentifier("ai.context.cards")
        }
    }
}

private struct AIContextCardChip: View {
    let card: AIContextCard
    @ObservedObject var model: AIWorkspaceModel
    let open: (AIContextCard) -> Void
    @State private var customRange = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: Self.symbol(card)).foregroundStyle(WorkspaceStyle.accent)
            VStack(alignment: .leading, spacing: 2) {
                Button(card.title) { open(card) }.buttonStyle(.plain).font(.caption.weight(.semibold)).lineLimit(1)
                if case .chat(_, _, _, _, let range) = card {
                    Menu(Self.describe(range)) {
                        Button("Последние 200") { set(.standard) }
                        Button("За неделю") { set(.lastDays(7)) }
                        Button("За месяц") { set(.lastDays(30)) }
                        Button("Период…") { customRange = true }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption2)
                    .accessibilityIdentifier("ai.context.range.\(card.id)")
                }
                status.font(.caption2).foregroundStyle(.secondary)
            }
            Button {
                Task { await model.remove(card.id) }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Убрать из контекста").accessibilityIdentifier("ai.context.remove.\(card.id)")
        }
        .padding(8).background(WorkspaceStyle.surface, in: .rect(cornerRadius: 8))
        .popover(isPresented: $customRange) { AIContextRangePicker { range in set(range) } }
    }

    @ViewBuilder private var status: some View {
        if let failure = model.previewFailures[card.id] {
            Text(failure.message).foregroundStyle(.orange)
        } else if let material = model.previews[card.id] {
            Text(Self.counts(material))
        } else {
            Text("Читается…")
        }
    }

    private func set(_ range: AIContextRange) { Task { await model.setRange(range, for: card.id) } }

    static func counts(_ material: AIContextMaterial) -> String {
        var parts: [String]
        switch material.card {
        case .chat:
            parts = ["\(material.lines.count) сообщ."]
            if let requested = material.requested, material.available < requested {
                parts.append("загружено локально \(material.available)")
            }
        case .letter: parts = ["письмо целиком"]
        case .contact: parts = ["досье"]
        }
        if material.hiddenForbidden > 0 { parts.append("скрыто \(material.hiddenForbidden) запрещённого контакта") }
        if material.hiddenProtected > 0 { parts.append("скрыто \(material.hiddenProtected) защищённых") }
        return parts.joined(separator: " · ")
    }

    static func describe(_ range: AIContextRange) -> String {
        switch range {
        case .latest(let count): "Последние \(count)"
        case .lastDays(7): "За неделю"
        case .lastDays(30): "За месяц"
        case .lastDays(let days): "За \(days) дн."
        case .between(let from, let to):
            "\(from.formatted(date: .numeric, time: .omitted)) – \(to.formatted(date: .numeric, time: .omitted))"
        }
    }

    static func symbol(_ card: AIContextCard) -> String {
        switch card {
        case .chat: "bubble.left.and.bubble.right"
        case .letter: "envelope"
        case .contact: "person.text.rectangle"
        }
    }
}

private struct AIContextRangePicker: View {
    let apply: (AIContextRange) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var to = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("С", selection: $from, displayedComponents: .date)
            DatePicker("По", selection: $to, in: from..., displayedComponents: .date)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Применить") {
                    let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: to) ?? to
                    apply(.between(Calendar.current.startOfDay(for: from), end))
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(14).frame(width: 260)
    }
}

/// "+" and "@": suggestions by title; choosing one attaches it.
struct AIContextSuggestionsList: View {
    @ObservedObject var search: AIContextSearch
    let choose: (AIContextSuggestion) -> Void

    var body: some View {
        if search.suggestions.isEmpty {
            Text("Ничего не найдено").font(.caption).foregroundStyle(.secondary).padding(8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.suggestions) { suggestion in
                        Button {
                            choose(suggestion)
                        } label: {
                            HStack {
                                Image(systemName: AIContextCardChip.symbol(suggestion.card)).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(suggestion.card.title).lineLimit(1)
                                    Text(suggestion.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }.contentShape(.rect).padding(.horizontal, 8).padding(.vertical, 5)
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("ai.context.suggestion.\(suggestion.id)")
                    }
                }
            }.frame(maxHeight: 240)
        }
    }
}

/// The "+" popover: a search field over the same suggestions.
struct AIContextAddPopover: View {
    @ObservedObject var search: AIContextSearch
    let choose: (AIContextSuggestion) -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Чат, письмо или контакт", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("ai.context.addQuery")
            AIContextSuggestionsList(search: search, choose: choose)
        }
        .padding(10).frame(width: 320)
        .onAppear { search.update(query: "") }
        .onChange(of: query) { _, value in search.update(query: value) }
    }
}
