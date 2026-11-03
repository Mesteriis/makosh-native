import SwiftUI
import MakoshMail

struct MailOutboxView: View {
    @ObservedObject var model: MailWorkspaceModel
    @State private var confirmation: MailSubmission?
    @State private var draftConfirmation: MailDraft?
    @State private var scheduleConfirmation: MailScheduledSend?
    @State private var ruleConfirmation: MailRuleOperation?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack { Text("Исходящие операции").font(.title2.bold());Spacer();Button("Закрыть") { dismiss() } }
            Text("Принятие SMTP-сервером не подтверждает доставку или прочтение. При неизвестном исходе повтор запрещён до вашей проверки.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach((model.automation.scheduled ?? []).filter { $0.state != .cancelled && $0.state != .completed }.sorted { $0.sendAt < $1.sendAt }) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.draft.subject.isEmpty ? "Без темы" : item.draft.subject).font(.headline)
                            Text("\(item.draft.to) · \(item.sendAt.formatted())").font(.caption)
                            if item.state == .pending {
                                Text("Ожидает срока, открытого Макоша и подключённого аккаунта.").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Отменить") { Task { await model.cancelSchedule(item) } }
                                    Button("Вернуть в редактор") { Task { await model.cancelSchedule(item, edit: true) } }
                                }.disabled(model.busy)
                            } else {
                                Text("Исход неизвестен · автоматический повтор заблокирован").font(.caption).foregroundStyle(.orange)
                                Button("Разрешить исход после проверки…") { scheduleConfirmation = item }.disabled(model.busy || model.synthetic)
                            }
                        }
                    }
                    ForEach(model.automation.ruleOperations.filter { $0.state == .preparationFailed }) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Правило для UID \(item.key.uid) не подготовлено").font(.caption).foregroundStyle(.orange)
                            Text(item.failure ?? "Не удалось сохранить полное письмо.").font(.caption)
                            HStack {
                                Button("Повторить подготовку") { Task { await model.retryRule(item) } }
                                Button("Отменить правило для письма") { Task { await model.retryRule(item, cancel: true) } }
                            }.disabled(model.busy)
                        }
                    }
                    ForEach(model.automation.ruleOperations.filter { $0.state == .admitted || $0.state == .unknown }) { item in
                        VStack(alignment: .leading) {
                            Text("Правило: перемещение в \(item.destination.title), UID \(item.key.uid) — исход неизвестен").font(.caption).foregroundStyle(.orange)
                            Button("Завершить операцию после проверки…") { ruleConfirmation = item }.disabled(model.busy || model.synthetic)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 180)
            ForEach(model.drafts.filter { $0.remoteSave?.unresolved == true }) { draft in
                VStack(alignment: .leading) {
                    Text("Сохранение черновика на сервере неизвестно: " + (draft.subject.isEmpty ? "Без темы" : draft.subject)).font(.headline)
                    Button("Разрешить исход после проверки папки Черновики…") { draftConfirmation = draft }.disabled(model.busy || model.synthetic)
                }
            }
            List(model.submissions.reversed()) { submission in
                VStack(alignment:.leading,spacing:6) {
                    Text(title(submission.state)).font(.headline)
                    Text(submission.date.formatted()).font(.caption).foregroundStyle(.secondary)
                    if submission.state == .accepted { Text(submission.sentCopySaved ? "Копия в Отправленных сохранена." : "Копия в Отправленных не подтверждена; это не повод повторять SMTP.").font(.caption) }
                    if submission.state == .unknown || submission.state == .submitting { Button("Разрешить исход после проверки…") { confirmation=submission }.disabled(model.busy || model.synthetic) }
                }.padding(.vertical,8)
            }
        }.padding(24).frame(width:640,height:500)
            .confirmationDialog("Проверьте письмо у получателя и в почтовом клиенте. Эта отметка изменит только локальное состояние и не отправит письмо.",isPresented:Binding(get:{confirmation != nil},set:{if !$0 {confirmation=nil}}),titleVisibility:.visible) {
                if let submission=confirmation {
                    Button("Подтверждаю: письмо отправлено") { Task { await model.resolveUnknown(submission.id,wasSent:true) };confirmation=nil }
                    Button("Подтверждаю: не отправлено; разрешить ручной повтор",role:.destructive) { Task { await model.resolveUnknown(submission.id,wasSent:false) };confirmation=nil }
                }
            }
            .confirmationDialog("Проверьте папку Черновики в другом почтовом клиенте. Отметка изменит только локальное состояние.", isPresented: Binding(get: { draftConfirmation != nil }, set: { if !$0 { draftConfirmation = nil } }), titleVisibility: .visible) {
                if let draft = draftConfirmation {
                    Button("Подтверждаю: черновик сохранён") { Task { await model.resolveDraftSave(draft, saved: true) }; draftConfirmation = nil }
                    Button("Подтверждаю: копии нет; разрешить ручное сохранение") { Task { await model.resolveDraftSave(draft, saved: false) }; draftConfirmation = nil }
                }
            }
            .confirmationDialog("Проверьте отправку у получателя. Эта отметка не отправит письмо; при подтверждённом отсутствии оно останется черновиком для ручной отправки.", isPresented: Binding(get: { scheduleConfirmation != nil }, set: { if !$0 { scheduleConfirmation = nil } }), titleVisibility: .visible) {
                if let item = scheduleConfirmation {
                    Button("Подтверждаю: отправлено") { Task { await model.resolveSchedule(item, wasSent: true) }; scheduleConfirmation = nil }
                    Button("Подтверждаю: не отправлено", role: .destructive) { Task { await model.resolveSchedule(item, wasSent: false) }; scheduleConfirmation = nil }
                }
            }
            .confirmationDialog("Проверьте исходную и целевую папки. Завершение изменит только локальную отметку; повторного перемещения не будет.", isPresented: Binding(get: { ruleConfirmation != nil }, set: { if !$0 { ruleConfirmation = nil } }), titleVisibility: .visible) {
                if let item = ruleConfirmation { Button("Проверено, завершить") { Task { await model.resolveRule(item) }; ruleConfirmation = nil } }
            }
    }
    private func title(_ state: MailSubmissionState) -> String {
        switch state {
        case .submitting,.unknown:"Исход неизвестен · повтор заблокирован"
        case .accepted:"SMTP-сервер принял письмо"
        case .rejected:"Отправка отклонена"
        case .userConfirmedSent:"Отправлено · подтверждено пользователем"
        case .userConfirmedNotSent:"Не отправлено · пользователь разрешил ручной повтор"
        }
    }
}
