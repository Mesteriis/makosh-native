import MakoshCalendar
import SwiftUI

/// The calendar section's left column.
struct CalendarSidebarColumn: View {
    @ObservedObject var host: CalendarHost
    var body: some View {
        Group {
            if let model = host.model {
                CalendarSidebar(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// The calendar section's detail: header, grid and task column (layout variant C).
struct CalendarDetailView: View {
    @ObservedObject var host: CalendarHost
    var body: some View {
        Group {
            if let model = host.model {
                CalendarSection(model: model, host: host)
            } else if let failure = host.failure {
                ContentUnavailableView(failure, systemImage: "calendar.badge.exclamationmark")
            } else {
                ProgressView("Открываю календарь…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct CalendarSection: View {
    @ObservedObject var model: CalendarWorkspaceModel
    @ObservedObject var host: CalendarHost
    @State private var showTasks = true
    @State private var selection: CalendarGridItem?
    @State private var sheet: CalendarEventSheetRequest?

    var body: some View {
        VStack(spacing: 0) {
            CalendarHeader(model: model, showTasks: $showTasks) { newEvent(start: nextHour(), minutes: 60) }
            Divider()
            HStack(spacing: 0) {
                Group {
                    if model.period.mode == .month {
                        CalendarMonthGrid(model: model) { day in
                            model.period = CalendarPeriod(mode: .day, anchor: day)
                            _Concurrency.Task { await model.refresh() }
                        }
                    } else {
                        CalendarWeekGrid(
                            model: model, selection: $selection, open: open,
                            create: { start, end in sheet = .init(start: start, end: end) },
                            moveSlot: host.slotMoved.map { handler in
                                { id, start, end in
                                    _Concurrency.Task {
                                        await handler(id, start, end)
                                        await model.refresh()
                                    }
                                }
                            })
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showTasks {
                    Divider()
                    CalendarTaskColumn(model: model)
                }
            }
            if let notice = model.notice {
                HStack {
                    Image(systemName: "info.circle")
                    Text(notice).font(.callout)
                    Spacer()
                    Button("Скрыть") { model.notice = nil }.buttonStyle(.borderless)
                }.padding(8).background(WorkspaceStyle.surface)
            }
        }
        .background { keys }
        .task { await model.refresh() }
        .onAppear { showTasks = model.snapshot?.preferences.showTasks ?? true }
        .onChange(of: host.openEventRequest) { _, id in
            guard let id else { return }
            host.openEventRequest = nil
            _Concurrency.Task {
                await model.refresh()
                if let event = model.event(id), case .timed(let start, let end, _) = event.time {
                    model.period = CalendarPeriod(mode: model.period.mode, anchor: start)
                    await model.refresh()
                    sheet = .init(eventID: id, start: start, end: end)
                }
            }
        }
        .sheet(item: $sheet) { request in
            CalendarEventCard(model: model, host: host, request: request) { sheet = nil }.makoshAppearance()
        }
        .sheet(item: Binding(get: { model.conflict }, set: { model.conflict = $0 })) { prompt in
            CalendarConflictSheet(model: model, prompt: prompt).makoshAppearance()
        }
        .sheet(isPresented: Binding(get: { model.groupPreview != nil }, set: { if !$0 { model.cancelGroupChange() } })) {
            if let preview = model.groupPreview { CalendarGroupPreviewSheet(model: model, preview: preview).makoshAppearance() }
        }
        .alert("Календарь", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Понятно", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .alert(
            "Отменить перенос встречи?", isPresented: Binding(get: { model.undoNeedsConfirmation }, set: { if !$0 { model.cancelUndo() } })
        ) {
            Button("Отменить перенос") { _Concurrency.Task { await model.confirmUndo() } }
            Button("Оставить", role: .cancel) { model.cancelUndo() }
        } message: {
            Text("Участники получат обновление приглашения ещё раз.")
        }
    }

    /// ←/→ period, T today, 1/2/3 day/week/month, Enter opens, ⌫ deletes the selected block, ⌘Z undoes a move.
    private var keys: some View {
        Group {
            Button("") {
                model.go(-1)
                refresh()
            }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") {
                model.go(1)
                refresh()
            }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") {
                model.today()
                refresh()
            }.keyboardShortcut("t", modifiers: [])
            Button("") {
                model.setMode(.day)
                refresh()
            }.keyboardShortcut("1", modifiers: [])
            Button("") {
                model.setMode(.week)
                refresh()
            }.keyboardShortcut("2", modifiers: [])
            Button("") {
                model.setMode(.month)
                refresh()
            }.keyboardShortcut("3", modifiers: [])
            Button("") { if let selection { open(selection) } }.keyboardShortcut(.return, modifiers: [])
            Button("") { if let selection { open(selection) } }.keyboardShortcut(.delete, modifiers: [])
            Button("") { _Concurrency.Task { await model.undoLastMove() } }.keyboardShortcut("z", modifiers: .command)
        }.hidden()
    }

    private func open(_ item: CalendarGridItem) {
        let event = model.event(item.occurrence.eventID)
        let series = (event?.masterID.flatMap(model.event) ?? event)?.recurrence != nil
        sheet = .init(
            eventID: item.occurrence.eventID, occurrenceKey: series ? item.occurrence.key : nil, start: item.occurrence.start,
            end: item.occurrence.end)
    }

    private func newEvent(start: Date, minutes: Int) {
        sheet = .init(start: start, end: start.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    private func nextHour() -> Date {
        let calendar = model.calendar, now = Date()
        let base =
            calendar.isDate(model.period.anchor, inSameDayAs: now)
            ? now : calendar.startOfDay(for: model.period.anchor).addingTimeInterval(9 * 3600)
        return calendar.dateInterval(of: .hour, for: base)!.end
    }

    private func refresh() { _Concurrency.Task { await model.refresh() } }
}
