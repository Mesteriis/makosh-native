import MakoshWhatsApp
import SwiftUI

struct WhatsAppOutgoingBatchView: View {
  @ObservedObject var model: WhatsAppComposerModel
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let snapshot = model.shownBatch {
        HStack {
          Text("Пакет · \(snapshot.children.count) файлов").font(.title2.bold())
          Spacer()
          Button("Закрыть") { model.dismissBatch() }
        }
        Text(
          "Файлы идут отдельными сообщениями. Подпись и ответ — у первого. Передача в WhatsApp ещё не подтверждает доставку."
        )
        .font(.callout).foregroundStyle(.secondary)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(snapshot.children) { child in
              VStack(alignment: .leading, spacing: 6) {
                HStack {
                  Text(file(child, snapshot: snapshot)?.name ?? "Файл").font(.headline).lineLimit(1)
                  Spacer()
                  if let size = file(child, snapshot: snapshot)?.size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .binary))
                      .foregroundStyle(.secondary)
                  }
                }
                Text(label(child.state)).font(.caption)
                if !child.content.text.isEmpty {
                  Text(child.content.text).lineLimit(3).textSelection(.enabled)
                }
                if let rejection = child.rejection {
                  Text("Сервер отклонил сообщение · \(rejection.code)").foregroundStyle(.red)
                }
                if snapshot.issue?.childID == child.id {
                  Text(snapshot.issue?.explanation ?? "").font(.caption).foregroundStyle(.orange)
                }
                if child.state == .unknown {
                  HStack {
                    Button("Получатель получил") { Task { await model.resolve(child, sent: true) } }
                    Button("Точно не отправлено") {
                      Task { await model.resolve(child, sent: false) }
                    }
                  }.disabled(model.batchBusy)
                }
                if child.state == .notSent || child.state == .rejected {
                  Button("Подготовить отдельную копию для повтора") {
                    Task { await model.resume(child, copy: true) }
                  }
                  .disabled(model.batchBusy)
                }
              }.buttonStyle(.bordered).padding(.vertical, 5).fixedSize(
                horizontal: false, vertical: true
              )
              .accessibilityElement(children: .contain)
              .accessibilityIdentifier("whatsapp.batch.child.\(child.id)")
              Divider()
            }
          }
        }
        if let issue = snapshot.issue, issue.childID == nil {
          Text(issue.explanation).foregroundStyle(.orange)
        }
        if snapshot.children.contains(where: { $0.state == .notSent || $0.state == .rejected }) {
          Text(
            "Продолжение пропустит уже отклонённые и точно не отправленные элементы. Их копии готовятся отдельно."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Обновить") { Task { await model.refreshShownBatch() } }.disabled(model.batchBusy)
          Spacer()
          if model.batchBusy { ProgressView().controlSize(.small) }
          Button("Отправить только оставшиеся") { Task { await model.continueShownBatch() } }
            .disabled(model.batchBusy || !model.canResume || !canContinue(snapshot))
            .accessibilityIdentifier("whatsapp.batch.continue")
        }
        if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
      }
    }.padding(20).frame(minWidth: 560, minHeight: 420)
      .accessibilityIdentifier("whatsapp.batch.sheet")
  }
  private func canContinue(_ snapshot: WhatsAppBatchSnapshot) -> Bool {
    snapshot.children.contains { $0.state == .prepared }
      && !snapshot.children.contains { $0.state == .unknown || $0.state == .dispatching }
  }
  private func file(_ child: WhatsAppOutgoing, snapshot: WhatsAppBatchSnapshot)
    -> WhatsAppPreparedFile?
  {
    guard let id = child.content.files.first else { return nil }
    return snapshot.files.first { $0.id == id }
  }
  private func label(_ state: WhatsAppOutgoing.State) -> String {
    switch state {
    case .prepared: "Подготовлено · ещё не отправлено"
    case .dispatching: "Выполняется"
    case .unknown: "Результат неизвестен · повтор заблокирован"
    case .sent: "Передано в WhatsApp"
    case .notSent: "Точно не отправлено"
    case .rejected: "Отклонено сервером"
    }
  }
}
