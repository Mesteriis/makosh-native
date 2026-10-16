import SwiftUI
import MakoshCore

struct MergeReviewView: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCandidate: DuplicateCandidate?
    @State private var survivor: UUID?
    @State private var error: String?
    @State private var submitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Объединения").font(.title2.bold()); Text("Совпадение — повод проверить, решение принимаете вы.").foregroundStyle(.secondary) }; Spacer(); Button("Готово") { dismiss() }.disabled(submitting) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Возможные дубликаты · \(model.duplicates.count)").font(.headline)
                    if model.duplicates.isEmpty { Text("Совпадений не найдено.").foregroundStyle(.secondary) }
                    ForEach(model.duplicates) { candidate in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("\(model.name(candidate.firstID))  ↔  \(model.name(candidate.secondID))").font(.headline)
                                ForEach(candidate.reasons, id: \.self) { reason in Text(reason).font(.callout).foregroundStyle(.secondary) }
                                Button("Проверить и объединить") { error = nil; survivor = nil; selectedCandidate = candidate }.disabled(!model.canWrite || submitting).accessibilityIdentifier("merge.review.\(candidate.id)")
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                    }
                    Divider()
                    Text("История объединений").font(.headline)
                    if model.merges.isEmpty { Text("Объединений пока нет.").foregroundStyle(.secondary) }
                    ForEach(model.merges) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) { Text("\(record.removedBefore.displayName) → \(record.survivorBefore.displayName)"); Text(record.mergedAt.formatted()).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if record.undoneAt == nil { Button("Отменить объединение") {
                                guard model.canWrite, !submitting else { return }
                                submitting = true
                                Task {
                                    defer { submitting = false }
                                    _ = await model.undo(record)
                                    if let message = model.error { error = message; model.error = nil }
                                }
                            }.disabled(!model.canWrite || submitting).accessibilityIdentifier("merge.undo.\(record.id)") }
                            else { Text("Отменено").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 6)
                    }
                }.padding(4)
            }
        }.padding(26).frame(width: 690, height: 560).interactiveDismissDisabled(submitting)
        .sheet(item: $selectedCandidate) { candidate in
                VStack(alignment: .leading, spacing: 18) {
                    Text("Какую карточку сохранить?").font(.title2.bold())
                    Text("Выберите основную карточку ниже, затем подтвердите объединение.").font(.callout).foregroundStyle(.secondary)
                    Text("Вторая карточка будет объединена с выбранной. При разных именах, компаниях и должностях останутся значения основной карточки; все исходные значения сохранятся в источниках. Заметки и история сохранятся. Если данные после объединения не менялись, действие можно отменить.").foregroundStyle(.secondary)
                    ScrollView {
                        HStack(alignment: .top, spacing: 12) {
                            reviewCard(candidate.firstID)
                            reviewCard(candidate.secondID)
                        }
                    }.frame(maxHeight: 240)
                    Picker("Основная карточка", selection: $survivor) {
                        Text(model.name(candidate.firstID)).tag(Optional(candidate.firstID))
                        Text(model.name(candidate.secondID)).tag(Optional(candidate.secondID))
                    }.pickerStyle(.radioGroup).accessibilityIdentifier("merge.survivor")
                    HStack { Button("Отмена") { selectedCandidate = nil }.disabled(submitting); Spacer(); Button("Подтвердить объединение") {
                        guard let survivor, model.canWrite, !submitting else { return }
                        submitting = true
                        Task {
                            defer { submitting = false }
                            if await model.merge(candidate, survivor: survivor) { selectedCandidate = nil }
                            else { error = model.error; model.error = nil }
                        }
                    }.buttonStyle(.borderedProminent).disabled(survivor == nil || !model.canWrite || submitting).accessibilityIdentifier("merge.confirm") }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(28).frame(width: 720).interactiveDismissDisabled(submitting)
        }
        .alert("Макош", isPresented: Binding(get: { error != nil && selectedCandidate == nil }, set: { if !$0 { error = nil } })) { Button("Понятно") { error = nil } } message: { Text(error ?? "") }
    }
    @ViewBuilder private func reviewCard(_ id: UUID) -> some View {
        if let contact = model.contacts.first(where: { $0.id == id }) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(contact.displayName).font(.headline)
                    Text(contact.organization.isEmpty ? "Компания не указана" : contact.organization)
                    Text(contact.jobTitle.isEmpty ? "Должность не указана" : contact.jobTitle).font(.callout).foregroundStyle(.secondary)
                    ForEach(contact.emails, id: \.self) { Text($0).font(.callout) }
                    ForEach(contact.phones, id: \.self) { Text($0).font(.callout) }
                    if contact.emails.isEmpty && contact.phones.isEmpty { Text("Нет почты и телефона").font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    if contact.identities.isEmpty { Text("Локальная карточка").font(.caption).foregroundStyle(.secondary) }
                    ForEach(contact.identities) { identity in
                        Text("\(identity.service) · аккаунт \(identity.accountID) · запись \(identity.externalID)").font(.caption).foregroundStyle(.secondary)
                    }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }.frame(maxWidth: .infinity)
        }
    }

}
