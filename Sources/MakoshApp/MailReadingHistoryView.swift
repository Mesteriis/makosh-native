import SwiftUI
import MakoshMail

struct MailTextBody: View {
    let text: String
    @State private var pages: [String] = []
    @State private var index = 0
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pages.count > 1 {
                HStack {
                    Button("Предыдущая") { index -= 1 }.disabled(index == 0)
                    Text("Страница \(index + 1) из \(pages.count)").font(.caption).monospacedDigit()
                    Button("Следующая") { index += 1 }.disabled(index + 1 >= pages.count)
                }.accessibilityIdentifier("mail.reading.pages")
            }
            if let error { Text(error).foregroundStyle(.red) }
            else if pages.isEmpty { ProgressView() }
            else { Text(pages[min(index, pages.count - 1)]).textSelection(.enabled).font(.body).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading) }
        }.task(id: text) {
            index = 0; pages = []; error = nil
            let task = Task.detached(priority: .userInitiated) { try MailTextPagination.pages(text) }
            do {
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !Task.isCancelled else { return }; pages = result
            } catch { if !Task.isCancelled { self.error = "Не удалось подготовить текст письма." } }
        }
    }
}
struct MailReadingHistoryView: View {
    @ObservedObject var model: MailWorkspaceModel
    let letter: MailLetter
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [MailLetterVersion] = []
    @State private var selected: Int64?
    @State private var html = false
    @State private var loading = false
    @State private var error: String?
    private var current: MailLetter? { versions.first { $0.id == selected }?.letter }
    var body: some View {
        VStack(alignment: .leading) {
            HStack { Text("Сохранённые версии").font(.title2.bold()); Spacer(); Button("Закрыть") { dismiss() } }.padding(20)
            HSplitView {
                VStack {
                    List(versions, selection: $selected) { version in
                        VStack(alignment: .leading) { Text("Версия \(version.id)").font(.headline); Text(version.letter.subject).lineLimit(2); Text(version.letter.removedFromSource == true ? "Удалено на сервере · копия сохранена" : "Сохранённая копия").font(.caption).foregroundStyle(.secondary) }.tag(version.id)
                    }
                    Button("Ещё версии") { Task { await load() } }.disabled(loading).padding()
                }.frame(minWidth: 180, idealWidth: 230, maxWidth: 300)
                VStack(alignment: .leading) {
                    if let current {
                        HStack { Text(current.subject).font(.headline); Spacer(); if current.html != nil { Toggle("HTML", isOn: $html).toggleStyle(.button) } }.padding()
                        if html, let content = current.html { MailHTMLView(html: content) }
                        else { ScrollView { MailTextBody(text: current.text ?? "Тело этой версии не было получено.").padding() } }
                        if !current.attachments.isEmpty { Text("Вложения этой версии: " + current.attachments.map(\.filename).joined(separator: ", ")).font(.caption).padding() }
                    } else { ContentUnavailableView("Выберите версию", systemImage: "clock.arrow.circlepath") }
                }.frame(minWidth: 380)
            }
            if let error { Text(error).foregroundStyle(.red).padding() }
            Text("История доступна только для чтения и не заменяет текущее письмо.").font(.caption).foregroundStyle(.secondary).padding()
        }.frame(minWidth: 760, idealWidth: 900, minHeight: 540, idealHeight: 650).task { await load() }
    }
    private func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do { let page = try await model.versions(letter.id, beforeSequence: versions.last?.id); versions.append(contentsOf: page); if selected == nil { selected = versions.first?.id } }
        catch { self.error = error.localizedDescription }
    }
}
