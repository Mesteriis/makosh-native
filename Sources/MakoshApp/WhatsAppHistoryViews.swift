import MakoshCore
import MakoshWhatsApp
import SwiftUI

struct WhatsAppSearchBar: View {
  @ObservedObject var history: WhatsAppHistoryModel
  @State private var query = ""
  @State private var filter = WhatsAppHistoryFilter.all
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        TextField("Поиск во всей сохранённой переписке", text: $query).textFieldStyle(
          .roundedBorder
        ).onSubmit { run() }
        Button("Найти", action: run).disabled(history.busy)
        Picker("Показать", selection: $filter) {
          Text("Все").tag(WhatsAppHistoryFilter.all)
          Text("Избранное").tag(WhatsAppHistoryFilter.starred)
          Text("Закреплённые").tag(WhatsAppHistoryFilter.pinned)
          Text("Медиа").tag(WhatsAppHistoryFilter.media)
          Text("Документы").tag(WhatsAppHistoryFilter.documents)
          Text("Ссылки").tag(WhatsAppHistoryFilter.links)
        }.frame(width: 170).onChange(of: filter) { _, _ in run() }
        if history.active {
          Button {
            query = ""
            filter = .all
            history.clear()
          } label: {
            Image(systemName: "xmark.circle")
          }.help("Закрыть поиск")
        }
      }
      if let error = history.error { Text(error).font(.caption).foregroundStyle(.red) }
    }.padding(.horizontal, 16).padding(.vertical, 8)
  }
  private func run() {
    if query.isEmpty && filter == .all {
      history.clear()
    } else {
      Task { await history.search(query: query, filter: filter) }
    }
  }
}
struct WhatsAppArchiveView: View {
  @StateObject private var model: WhatsAppArchiveModel
  @Environment(\.dismiss) private var dismiss
  @State private var attachment: WhatsAppFileLease?
  @State private var file: WhatsAppFileLease?
  let messageID: String?
  init(worker: any WhatsAppServing, accountID: UUID, chat: String, messageID: String? = nil) {
    _model = StateObject(wrappedValue: .init(worker: worker, accountID: accountID, chat: chat))
    self.messageID = messageID
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(messageID == nil ? "Постоянный архив" : "Версии сообщения").font(.title2.bold())
        Spacer()
        Button("Закрыть") { dismiss() }
      }
      Text(
        "Все полученные версии сохранены. Удаление и истечение статуса в WhatsApp не удаляют архив."
      ).foregroundStyle(.secondary)
      List(
        model.rows.filter { row in
          messageID.map { id in row.observation.identity.messageID.utf8.elementsEqual(id.utf8) }
            ?? true
        }
      ) { row in
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(row.observation.observedAt, style: .date)
            Text(row.observation.observedAt, style: .time)
            Spacer()
            Text(row.observation.source.rawValue)
          }.font(.caption).foregroundStyle(.secondary)
          switch row.observation.event {
          case .message(let content):
            if let message = model.richMessages[row.id] {
              WhatsAppMessageRow(message: message, open: {}).disabled(true)
            } else {
              Text(content.text.isEmpty ? "Вложение" : content.text).textSelection(.enabled)
            }
            ForEach(content.attachments, id: \.id) { item in
              Button(item.name.isEmpty ? item.kind : item.name) {
                Task {
                  do {
                    attachment?.remove()
                    attachment = try await model.worker.downloadVersion(
                      accountID: model.accountID, chat: model.chat,
                      id: row.observation.identity.messageID, resource: item.id, kind: item.kind,
                      name: item.name)
                  } catch { model.error = error.localizedDescription }
                }
              }.font(.caption)
            }
          case .deleted: Label("Удалено в WhatsApp", systemImage: "archivebox")
          case .removedFromSource: Text("Удалено из кеша источника")
          }
        }.padding(.vertical, 6).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Button("Ранее") { Task { await model.more() } }.disabled(model.busy || !model.hasMore)
        Spacer()
        Button("Экспорт всей переписки…") {
          Task {
            file?.remove()
            file = await model.export()
          }
        }.disabled(model.busy)
        if let file { ShareLink("Сохранить JSONL", item: file.url) }
      }
      if let error = model.error { Text(error).foregroundStyle(.red) }
    }.padding(20).frame(minWidth: 650, minHeight: 500).task { await model.more() }.sheet(
      isPresented: Binding(
        get: { attachment != nil },
        set: {
          if !$0 {
            attachment?.remove()
            attachment = nil
          }
        })
    ) { if let attachment { WhatsAppFilePreview(lease: attachment) } }.onDisappear {
      file?.remove()
      attachment?.remove()
    }
  }
}
struct WhatsAppStatusView: View {
  @StateObject private var history: WhatsAppHistoryModel
  let worker: any WhatsAppServing, accountID: UUID
  @Environment(\.dismiss) private var dismiss
  @State private var archive = false
  init(worker: any WhatsAppServing, accountID: UUID) {
    self.worker = worker
    self.accountID = accountID
    _history = StateObject(
      wrappedValue: .init(worker: worker, accountID: accountID, chat: "status@broadcast"))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Статусы").font(.title2.bold())
        Spacer()
        Button("Постоянный архив") { archive = true }
        Button("Закрыть") { dismiss() }
      }
      if history.messages.isEmpty && !history.busy {
        ContentUnavailableView(
          "Нет текущих статусов", systemImage: "circle.dashed",
          description: Text("После 24 часов статус остаётся в постоянном архиве."))
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(history.messages) { message in
            VStack(alignment: .leading) {
              Text(message.sender).font(.caption).foregroundStyle(.secondary)
              WhatsAppStatusRow(message: message, worker: worker, accountID: accountID)
            }
          }
        }
      }
      if history.hasMore {
        Button("Ещё") { Task { await history.loadMore() } }.disabled(history.busy)
      }
      if let error = history.error { Text(error).foregroundStyle(.red) }
    }.padding(20).frame(minWidth: 650, minHeight: 500).task {
      await history.search(query: "", filter: .currentStatus)
    }
    .sheet(isPresented: $archive) {
      WhatsAppArchiveView(worker: worker, accountID: accountID, chat: "status@broadcast")
    }
  }
}
private struct WhatsAppStatusRow: View {
  let message: WhatsAppMessage, worker: any WhatsAppServing, accountID: UUID
  @State private var preview: WhatsAppFileLease?
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading) {
      WhatsAppMessageRow(
        message: message,
        open: {
          Task {
            do {
              preview?.remove()
              preview = try await worker.download(
                accountID: accountID, chat: message.chat, id: message.id)
            } catch { self.error = error.localizedDescription }
          }
        })
      if let error { Text(error).foregroundStyle(.red) }
    }
    .sheet(
      isPresented: Binding(
        get: { preview != nil },
        set: {
          if !$0 {
            preview?.remove()
            preview = nil
          }
        })
    ) { if let preview { WhatsAppFilePreview(lease: preview) } }.onDisappear { preview?.remove() }
  }
}
