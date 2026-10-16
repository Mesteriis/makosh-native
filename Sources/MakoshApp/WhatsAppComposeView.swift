import MakoshWhatsApp
import SwiftUI
import UniformTypeIdentifiers

struct WhatsAppComposeView: View {
  @ObservedObject var model: WhatsAppComposerModel
  let accountID: UUID?, chatID: String?
  var rich: () -> Void = {}
  @State private var choosing = false
  @State private var outbox = false
  @State private var asFiles = true
  @State private var pickerAccount: UUID?
  @State private var pickerChat: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let reply = model.reply {
        HStack {
          Label(
            reply.text.isEmpty ? reply.kind : reply.text, systemImage: "arrowshape.turn.up.left"
          ).lineLimit(2)
          Spacer()
          Button {
            model.clearReply()
          } label: {
            Image(systemName: "xmark")
          }
        }.font(.callout).padding(8).background(
          .green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
      }
      if model.reply == nil,model.restoredReplyID != nil {
        HStack { Label("Ответ на сохранённое сообщение",systemImage:"arrowshape.turn.up.left");Spacer();Button("Убрать ответ") { model.clearReply() } }.font(.callout)
      }
      if !model.photoDrafts.isEmpty {
        HStack {
          Button("Редактировать фото · \(model.photoDrafts.count)") { Task { await model.editPhotos() } }
            .accessibilityIdentifier("whatsapp.photo.open")
        }
      }
      if model.admittedDraft != nil {
        Button("Черновик уже принят · открыть очередь") { outbox=true;Task { await model.refreshOutbox() } }
      }
      Text("До 10 файлов · каждый до 100 МиБ · всего до 1000 МиБ").font(.caption).foregroundStyle(.secondary)
      if !model.orderedItems.isEmpty {
        ScrollView {
          VStack(spacing:6) {
            ForEach(Array(model.orderedItems.enumerated()),id:\.element.id) { index,item in
              HStack {
                Label(itemName(item),systemImage:itemIcon(item)).lineLimit(1)
                Spacer()
                Button { model.moveItem(from:index,to:index-1) } label: { Image(systemName:"chevron.up") }
                  .disabled(index == 0).help("Поднять вложение").accessibilityLabel("Поднять вложение")
                Button { model.moveItem(from:index,to:index+1) } label: { Image(systemName:"chevron.down") }
                  .disabled(index == model.orderedItems.count-1).help("Опустить вложение").accessibilityLabel("Опустить вложение")
                Button { switch item { case .file(let id):model.removeAttachment(id:id);case .photo(let id):model.removePhoto(id:id) } } label: { Image(systemName:"xmark.circle") }
                  .help("Убрать вложение").accessibilityLabel("Убрать вложение")
              }.font(.callout).accessibilityIdentifier("whatsapp.compose.file.\(item.id)")
            }
          }
        }.frame(maxHeight:min(CGFloat(model.orderedItems.count)*32,180))
          .disabled(!model.matchesContext(account:accountID,chat:chatID))
      }
      if model.preparing {
        HStack {
          ProgressView().controlSize(.small)
          Text("Подготовка файлов…").font(.caption)
          Button("Отменить подготовку") {
            if model.matchesContext(account: accountID, chat: chatID) { model.cancelPreparation() }
          }.accessibilityIdentifier("whatsapp.compose.cancelPreparation")
        }
      }
      if let text = model.error {
        Text(text).foregroundStyle(.red).font(.caption).textSelection(.enabled)
        Button("Загрузить сохранённый черновик (заменит локальные правки)") { Task { await model.reloadSavedDraft() } }
          .font(.caption).disabled(model.sending || model.preparing)
      }
      if let text = model.notice { Text(text).foregroundStyle(.secondary).font(.caption) }
      HStack(alignment: .bottom, spacing: 10) {
        Menu {
          Button("Файлы") { choose(asFiles: true) }
          Button("Фото и медиа") { choose(asFiles: false) }
          Button("Геопозиция, контакт, опрос", action: rich)
        } label: {
          Image(systemName: "plus.circle")
        }.menuStyle(.borderlessButton).accessibilityLabel("Прикрепить файл или сообщение").help("Прикрепить файл").disabled(
          model.preparing || model.sending || model.attachments.count + model.photoDrafts.count >= 10
        ).accessibilityIdentifier("whatsapp.compose.attach")
        TextField(
          "Сообщение",
          text: Binding(
            get: { model.draftText(account: accountID, chat: chatID) },
            set: { model.setDraftText($0, account: accountID, chat: chatID) }), axis: .vertical
        ).lineLimit(1...6).textFieldStyle(.plain).padding(10).background(
          .background, in: RoundedRectangle(cornerRadius: 16)
        ).onSubmit { Task { await model.send(expectedAccount: accountID, expectedChat: chatID) } }
          .accessibilityIdentifier("whatsapp.compose.text")
        WhatsAppVoiceRecordingView(
          model: model.voice,
          start: { model.recordVoice(expectedAccount: accountID, expectedChat: chatID) }
        ).disabled(!model.attachments.isEmpty || !model.photoDrafts.isEmpty || model.preparing || model.sending)
        Button {
          outbox = true
          Task { await model.refreshOutbox() }
        } label: {
          Image(systemName: "tray")
        }.help("Очередь отправки").accessibilityIdentifier("whatsapp.outbox")
        Button {
          Task { await model.send(expectedAccount: accountID, expectedChat: chatID) }
        } label: {
          Image(systemName: model.sending ? "hourglass" : "arrow.up.circle.fill").font(.title2)
        }.disabled(
          model.sending || model.preparing || model.voice.recording || model.voice.preparing
            || (model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              && model.attachments.isEmpty && model.photoDrafts.isEmpty)
        ).help("Отправить").accessibilityIdentifier("whatsapp.compose.send")
      }
    }.padding(12)
      .fileImporter(isPresented: $choosing, allowedContentTypes: asFiles ? [.item] : [.image, .movie, .audio], allowsMultipleSelection: true) { result in
        if case .success(let urls) = result {
          let account = pickerAccount, chat = pickerChat, mode = asFiles
          Task {
            await model.attach(urls, asFiles: mode, targetAccount: account, targetChat: chat)
            if !mode,model.matchesContext(account:account,chat:chat) { await model.editPhotos() }
          }
        }
      }
      .sheet(isPresented: $model.showPhotoEditor,onDismiss: { model.photoEditor.cancel() }) {
        WhatsAppPhotoEditorView(model:model.photoEditor,caption:Binding(get:{ model.draftText(account:accountID,chat:chatID) },set:{ model.setDraftText($0,account:accountID,chat:chatID) }),mode:$model.photoMode,
          cancel:{ Task { await model.finishPhotoEditor(send:false) } },send:{ Task { await model.finishPhotoEditor(send:true) } })
      }
      .sheet(isPresented: $outbox) { WhatsAppOutboxView(model: model) }
  }
  private func itemName(_ item:WhatsAppComposeItem) -> String {
    switch item {
    case .file(let id):return model.attachments.first { $0.id == id }?.name ?? "Файл"
    case .photo(let id):return "Фото \((model.photoDrafts.firstIndex { $0.id == id } ?? 0)+1)"
    }
  }
  private func itemIcon(_ item:WhatsAppComposeItem) -> String { if case .photo = item { return "photo" };return "paperclip" }
  private func choose(asFiles: Bool) {
    self.asFiles = asFiles; pickerAccount = accountID; pickerChat = chatID; choosing = true
  }
  private func move(_ id: UUID, offset: Int) {
    guard model.matchesContext(account: accountID, chat: chatID),
      let index = model.attachments.firstIndex(where: { $0.id == id }) else { return }
    model.moveAttachment(from: index, to: index + offset)
  }
}
private struct WhatsAppOutboxView: View {
  @ObservedObject var model: WhatsAppComposerModel
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Очередь WhatsApp").font(.title2.bold())
        Spacer()
        Button("Закрыть") { dismiss() }
      }
      Text(
        "«Передано ядру» ещё не означает доставку. Неизвестный результат нужно проверить у получателя перед повтором."
      ).foregroundStyle(.secondary)
      ScrollView {
       LazyVStack(alignment:.leading,spacing:12) {
        ForEach(model.outbox) { value in
        VStack(alignment: .leading, spacing: 8) {
          Text(value.content.text.isEmpty ? value.content.kind : value.content.text).lineLimit(3)
          if let rejection = value.rejection { Text("Сервер отклонил сообщение · код \(rejection.code)").foregroundStyle(.red) }
          Text(label(value.state)).font(.caption).foregroundStyle(.secondary)
          if value.batchID != nil {
            Button("Показать пакет и оставшиеся файлы") { Task { await model.showBatch(value) } }
              .accessibilityIdentifier("whatsapp.batch.open.\(value.id)")
          }
          if value.content.action?.op.rawValue.hasPrefix("call_") != true {
            if value.state == .prepared && value.batchID == nil {
              Button("Отправить подготовленное") { Task { await model.resume(value) } }.disabled(
                !model.canResume)
            }
            if value.state == .notSent || value.state == .rejected {
              Button("Подготовить копию для повтора") {
                Task { await model.resume(value, copy: true) }
              }
            }
          }
          if value.state == .unknown {
            HStack {
              Button("Получатель получил") { Task { await model.resolve(value, sent: true) } }
              Button("Точно не отправлено") { Task { await model.resolve(value, sent: false) } }
            }
          }
        }.buttonStyle(.bordered).padding(.vertical, 5).fixedSize(horizontal: false, vertical: true)
          .accessibilityElement(children:.contain)
        Divider()
        }
       }
      }
      if model.outboxHasMore { Button("Ранее") { Task { await model.moreOutbox() } }.disabled(model.outboxLoading) }
      if let error = model.error { Text(error).foregroundStyle(.red) }
    }.padding(20).frame(minWidth: 520, minHeight: 400).task { await model.refreshOutbox() }
      .sheet(isPresented: Binding(get: { model.shownBatch != nil }, set: { if !$0 { model.dismissBatch() } })) {
        WhatsAppOutgoingBatchView(model: model)
      }
  }
  private func label(_ state: WhatsAppOutgoing.State) -> String {
    switch state {
    case .prepared: "Подготовлено"
    case .dispatching: "Выполняется"
    case .unknown: "Результат неизвестен · повтор заблокирован"
    case .sent: "Передано ядру"
    case .notSent: "Не отправлено"
    case .rejected: "Отклонено сервером · автоматический повтор запрещён"
    }
  }
}

private struct WhatsAppVoiceRecordingView: View {
  @ObservedObject var model: WhatsAppVoiceRecordingModel
  let start: () -> Void
  var body: some View {
    HStack {
      if model.recording {
        Text("\(model.seconds) с").monospacedDigit().foregroundStyle(.red)
        Button {
          model.cancel()
        } label: {
          Image(systemName: "xmark")
        }.help("Отменить запись")
        Button {
          Task { await model.finish() }
        } label: {
          Image(systemName: "stop.circle.fill")
        }.help("Подготовить голосовое")
      } else {
        Button(action: start) { Image(systemName: model.preparing ? "hourglass" : "mic") }.help(
          "Записать голосовое"
        ).disabled(model.preparing || !model.canRecord)
      }
    }.alert(
      "Голосовое сообщение",
      isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button("Понятно") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }
}
