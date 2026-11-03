import SwiftUI
import MakoshTelegram

extension TelegramSearchMediaFilter {
    var title: String {
        switch self {
        case .all: "Все"
        case .photoVideo: "Фото и видео"
        case .photos: "Фото"
        case .videos: "Видео"
        case .links: "Ссылки"
        case .music: "Музыка"
        case .voiceOrVideo: "Голосовые"
        case .voice: "Голосовые сообщения"
        case .roundVideo: "Видеосообщения"
        case .gifs: "GIF"
        case .files: "Файлы"
        }
    }
}

extension TelegramSearchScope {
    var title: String {
        switch self {
        case .all: "Все диалоги"
        case .privateChats: "Личные"
        case .groups: "Группы"
        case .channels: "Каналы"
        }
    }
}

struct TelegramSearchMediaTabs: View {
    @Binding var selection: TelegramSearchMediaFilter
    private let filters: [TelegramSearchMediaFilter] = [.all, .photos, .videos, .links, .music, .voiceOrVideo, .gifs, .files]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(filters) { filter in
                    Button { selection = filter } label: {
                        Text(filter.title).font(.callout.weight(selection == filter ? .semibold : .regular))
                            .foregroundStyle(selection == filter ? Color.accentColor : Color.secondary)
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) { if selection == filter { Capsule().fill(Color.accentColor).frame(height: 2) } }
                    }.buttonStyle(.plain).accessibilityIdentifier("telegram.globalSearch.media.\(filter.rawValue)")
                }
            }.padding(.horizontal, 12)
        }.scrollIndicators(.hidden).frame(height: 40)
    }
}

/// Reference ChatSearchHeader: 44pt row, left navigation, 30pt input,
/// group sender token, calendar and trailing cancellation.
struct TelegramMessageSearchHeader: View {
    @ObservedObject var search: TelegramSearchModel
    @ObservedObject private var senders: TelegramSearchSenders
    @FocusState private var focused: Bool
    @State private var senderPresented = false
    @State private var calendarPresented = false
    @State private var date = Date()
    var initialDate: Date
    var focusRequest: UUID
    var close: () -> Void
    init(search: TelegramSearchModel, initialDate: Date, focusRequest: UUID, close: @escaping () -> Void) {
        self.search = search; self.senders = search.senders; self.initialDate = initialDate; self.focusRequest = focusRequest; self.close = close
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: search.selectOlderResult) { Image(systemName: "chevron.up").frame(width: 22, height: 28) }
                    .disabled(!search.canSelectOlder).help("Предыдущее совпадение — старее")
                    .accessibilityLabel("Предыдущее совпадение").accessibilityIdentifier("telegram.messageSearch.older")
                Button(action: search.selectNewerResult) { Image(systemName: "chevron.down").frame(width: 22, height: 28) }
                    .disabled(!search.canSelectNewer).help("Следующее совпадение — новее")
                    .accessibilityLabel("Следующее совпадение").accessibilityIdentifier("telegram.messageSearch.newer")
                TextField("Поиск сообщений в диалоге", text: $search.messageQuery)
                    .textFieldStyle(.roundedBorder).frame(height: 30).focused($focused)
                    .accessibilityIdentifier("telegram.messageSearch").onExitCommand(perform: close)
                if search.hasMessageQuery {
                    Button { search.showsResults.toggle() } label: {
                        Text(search.selectedResultIndex.map { "\($0 + 1) / \(search.totalMessages)" } ?? "\(search.totalMessages)")
                            .font(.caption.monospacedDigit())
                    }.help("Показать список результатов").accessibilityLabel("Список результатов")
                        .accessibilityIdentifier("telegram.messageSearch.list")
                }
                if senders.available {
                    Button {
                        senderPresented = true; senders.retry()
                    } label: {
                        Text(search.senderID.flatMap { id in senders.candidates.first(where: { $0.id == id })?.title }.map { "От: \($0)" } ?? "От")
                            .lineLimit(1).frame(maxWidth: 130)
                    }.accessibilityIdentifier("telegram.messageSearch.sender")
                        .popover(isPresented: $senderPresented) { senderPicker }
                }
                Button { date = initialDate; calendarPresented = true } label: { Image(systemName: "calendar") }
                    .help("Перейти к дате").accessibilityLabel("Перейти к дате")
                    .accessibilityIdentifier("telegram.messageSearch.calendar")
                    .popover(isPresented: $calendarPresented) {
                        VStack(spacing: 12) {
                            DatePicker("Дата", selection: $date, displayedComponents: .date).datePickerStyle(.graphical)
                                .accessibilityIdentifier("telegram.messageSearch.date")
                            Button("Перейти") { search.jumpToDate(date); calendarPresented = false }
                                .accessibilityIdentifier("telegram.messageSearch.date.go")
                        }.padding(16).frame(width: 300)
                    }
                Button("Отмена", action: close).accessibilityIdentifier("telegram.messageSearch.close")
            }.buttonStyle(.plain).padding(.horizontal, 10).frame(height: 44)
            if search.dateStatus == .loading {
                ProgressView("Переход к дате…").controlSize(.small).padding(8)
            } else if search.dateStatus == .failed || search.dateStatus == .timedOut {
                Text("Сообщение для этой даты недоступно. Можно повторить переход.").font(.caption).foregroundStyle(.secondary).padding(8)
                    .accessibilityIdentifier("telegram.messageSearch.date.error")
            }
        }.onAppear { focused = true }.onChange(of: focusRequest) { _, _ in focused = true }
    }

    private var senderPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Имя участника", text: $senders.query).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("telegram.messageSearch.sender.query")
            if search.senderID != nil {
                Button("Любой автор") { search.senderID = nil; senderPresented = false }
                    .accessibilityIdentifier("telegram.messageSearch.sender.clear")
            }
            TelegramSearchStatusView(status: senders.status, retry: senders.retry)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(senders.candidates) { sender in
                        Button { search.senderID = sender.id; senderPresented = false } label: {
                            Text(sender.title).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("telegram.messageSearch.sender.\(sender.id)")
                    }
                }
            }
            if senders.status == .ready && senders.candidates.isEmpty { Text("Участники не найдены").foregroundStyle(.secondary) }
        }.padding(12).frame(width: 280, height: 260)
    }
}
