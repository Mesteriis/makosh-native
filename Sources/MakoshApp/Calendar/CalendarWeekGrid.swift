import MakoshCalendar
import SwiftUI

/// Day and week view: an all-day strip with task due marks, an hour gutter and day columns
/// with working-hours shading, blocks laid out side by side, drag to create, move and resize,
/// and tasks dropped from the task column.
struct CalendarWeekGrid: View {
    @ObservedObject var model: CalendarWorkspaceModel
    @Binding var selection: CalendarGridItem?
    var open: (CalendarGridItem) -> Void
    var create: (Date, Date) -> Void
    var moveSlot: ((UUID, Date, Date) -> Void)?

    var body: some View {
        let days = model.period.days(calendar: model.calendar)
        VStack(spacing: 0) {
            CalendarDayHeaders(days: days, calendar: model.calendar)
            allDayStrip(days)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        gutter
                        ForEach(days, id: \.self) { day in
                            CalendarDayColumn(model: model, day: day, selection: $selection, open: open, create: create, moveSlot: moveSlot)
                        }
                    }
                    .frame(height: CalendarStyle.hourHeight * 24)
                    .overlay(alignment: .top) { Color.clear.frame(height: 1).id("eight").offset(y: CalendarStyle.hourHeight * 8) }
                }
                .onAppear { proxy.scrollTo("eight", anchor: .top) }
            }
        }
    }

    private func allDayStrip(_ days: [Date]) -> some View {
        let rows = model.allDayRows(days: days)
        let marks = model.dueMarks
        return HStack(alignment: .top, spacing: 0) {
            Text("весь день").font(.caption2).foregroundStyle(.secondary).frame(width: CalendarStyle.gutterWidth)
            ForEach(Array(days.enumerated()), id: \.element) { index, day in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows[index], id: \.eventID) { occurrence in
                        let event = model.event(occurrence.eventID)
                        Text(event?.title ?? "").font(.caption).lineLimit(1).padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, minHeight: CalendarStyle.allDayRowHeight, alignment: .leading)
                            .background(
                                CalendarStyle.color(model.collection(occurrence.collectionID)?.color ?? "").opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 4))
                    }
                    ForEach(marks[model.calendar.startOfDay(for: day)] ?? []) { task in
                        Label(task.title, systemImage: "flag").font(.caption2).lineLimit(1).foregroundStyle(
                            task.overdue ? .red : .secondary
                        )
                        .help("Срок задачи")
                    }
                }.padding(2).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }.frame(minHeight: CalendarStyle.allDayRowHeight + 4)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var gutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: CalendarStyle.gutterWidth, height: CalendarStyle.hourHeight, alignment: .topTrailing).padding(
                        .trailing, 4)
            }
        }
    }
}

/// Only the timed grid scrolls/expands; header spacers never claim its height.
struct CalendarDayHeaders: View {
    let days: [Date]
    let calendar: Calendar

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CalendarStyle.gutterWidth, height: CalendarStyle.dayHeaderHeight)
            ForEach(days, id: \.self) { day in
                let today = calendar.isDateInToday(day)
                Text(DateFormatter.calendar("EEd").string(from: day).capitalized)
                    .font(.callout.weight(today ? .bold : .regular))
                    .foregroundStyle(today ? WorkspaceStyle.accent : .primary)
                    .lineLimit(1).frame(maxWidth: .infinity)
            }
        }
        .frame(height: CalendarStyle.dayHeaderHeight)
        .accessibilityIdentifier("calendar.grid.dayHeaders")
    }
}

/// One day: shading, hour lines, blocks, drag gestures and the task drop target.
struct CalendarDayColumn: View {
    @ObservedObject var model: CalendarWorkspaceModel
    let day: Date
    @Binding var selection: CalendarGridItem?
    var open: (CalendarGridItem) -> Void
    var create: (Date, Date) -> Void
    var moveSlot: ((UUID, Date, Date) -> Void)?
    @State private var creating: (start: CGFloat, end: CGFloat)?
    @State private var dragging: (id: String, offset: CGFloat, resize: Bool)?

    private var dayStart: Date { model.calendar.startOfDay(for: day) }
    private func minute(_ y: CGFloat) -> Int {
        let raw = Int(y / CalendarStyle.hourHeight * 60)
        return max(0, min(24 * 60, raw / CalendarStyle.snapMinutes * CalendarStyle.snapMinutes))
    }
    private func y(_ minute: Int) -> CGFloat { CGFloat(minute) / 60 * CalendarStyle.hourHeight }
    private func date(_ minute: Int) -> Date { dayStart.addingTimeInterval(TimeInterval(minute * 60)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                (model.calendar.isDateInToday(day) ? CalendarStyle.todayTint : Color.clear)
                ForEach(Array(model.workingHours(day: day).enumerated()), id: \.offset) { _, range in
                    CalendarStyle.workingShade.frame(height: y(range.upperBound) - y(range.lowerBound)).offset(y: y(range.lowerBound))
                }
                ForEach(0..<24, id: \.self) { hour in
                    CalendarStyle.hourLine.frame(height: 1).offset(y: CGFloat(hour) * CalendarStyle.hourHeight)
                }
                Color.clear.contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in creating = (value.startLocation.y, value.location.y) }
                            .onEnded { value in
                                let a = minute(min(value.startLocation.y, value.location.y)),
                                    b = minute(max(value.startLocation.y, value.location.y))
                                creating = nil
                                create(date(a), date(max(b, a + CalendarStyle.snapMinutes)))
                            }
                    )
                    .onTapGesture(count: 2) { location in
                        let start = minute(location.y)
                        create(date(start), date(start + 60))
                    }
                if let creating {
                    WorkspaceStyle.accent.opacity(0.3).clipShape(RoundedRectangle(cornerRadius: CalendarStyle.blockRadius))
                        .frame(height: abs(creating.end - creating.start)).offset(y: min(creating.start, creating.end))
                }
                ForEach(model.visibleOccurrences(day: day)) { item in
                    block(item, width: geometry.size.width)
                }
                if model.calendar.isDateInToday(day) {
                    let now = Date()
                    Rectangle().fill(Color.red).frame(height: 1.5).offset(y: y(Int(now.timeIntervalSince(dayStart) / 60)))
                }
            }
            .dropDestination(for: String.self) { items, location in
                guard let id = items.first.flatMap(UUID.init(uuidString:)), let task = model.tasks.first(where: { $0.id == id }) else {
                    return false
                }
                _Concurrency.Task { await model.dropTask(task, at: date(minute(location.y))) }
                return true
            }
        }
        .frame(maxWidth: .infinity).frame(height: CalendarStyle.hourHeight * 24)
        .overlay(alignment: .leading) { Rectangle().fill(CalendarStyle.hourLine).frame(width: 1) }
    }

    @ViewBuilder private func block(_ item: CalendarGridItem, width: CGFloat) -> some View {
        let event = model.event(item.occurrence.eventID)
        let copy = event?.isBusyCopy == true
        let color = CalendarStyle.color(model.collection(item.occurrence.collectionID)?.color ?? "")
        let columnWidth = max(20, (width - 4) / CGFloat(item.columns))
        let shift = dragging?.id == item.id ? dragging!.offset : 0
        let resizing = dragging?.id == item.id && dragging!.resize
        let top = y(item.startMinute) + (resizing ? 0 : shift)
        let height = max(14, y(item.endMinute) - y(item.startMinute) + (resizing ? shift : 0))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: CalendarStyle.blockRadius).fill(copy ? Color.gray.opacity(0.22) : color.opacity(0.32))
            if copy {
                CalendarHatch().stroke(Color.white.opacity(0.12), lineWidth: 1).clipShape(
                    RoundedRectangle(cornerRadius: CalendarStyle.blockRadius))
            } else {
                Rectangle().fill(color).frame(width: 3)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title(event, copy: copy)).font(.caption.weight(.medium)).lineLimit(height > 30 ? 2 : 1)
                if height > 34, let event, !copy {
                    Text(
                        DateFormatter.calendar("Hm").string(from: item.occurrence.start)
                            + (event.meetingURL != nil ? " · встреча" : "")
                    ).font(.caption2).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).foregroundStyle(.secondary)
                }
            }.padding(.leading, copy ? 5 : 7).padding(.top, 3).padding(.trailing, 3)
            if !copy {
                Color.clear.frame(height: 6).frame(maxHeight: .infinity, alignment: .bottom).contentShape(Rectangle())
                    .gesture(drag(item, resize: true))
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            }
        }
        .frame(width: columnWidth - 2, height: height)
        .overlay {
            if selection?.id == item.id {
                RoundedRectangle(cornerRadius: CalendarStyle.blockRadius).stroke(WorkspaceStyle.accent, lineWidth: 2)
            }
        }
        .offset(x: 2 + CGFloat(item.column) * columnWidth, y: top)
        .onTapGesture { selection = item }
        .simultaneousGesture(TapGesture(count: 2).onEnded { open(item) })
        .gesture(copy ? nil : drag(item, resize: false))
        .help(copy ? "Занято: плашку меняет только исходное событие" : event?.title ?? "")
        .accessibilityIdentifier(copy ? "calendar.block.copy" : "calendar.block")
    }

    private func title(_ event: CalendarEvent?, copy: Bool) -> String {
        guard let event else { return "" }
        guard copy else { return event.title.isEmpty ? "Без названия" : event.title }
        let source = event.busyMarker.flatMap { model.event($0.sourceEventID) }
        return "Занято" + (source.flatMap { model.collection($0.collectionID) }.map { " · " + $0.name } ?? "")
    }

    private func drag(_ item: CalendarGridItem, resize: Bool) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in dragging = (item.id, value.translation.height, resize) }
            .onEnded { value in
                dragging = nil
                let delta =
                    Int((value.translation.height / CalendarStyle.hourHeight * 60) / Double(CalendarStyle.snapMinutes))
                    * CalendarStyle.snapMinutes
                guard delta != 0, let event = model.event(item.occurrence.eventID),
                    case .timed(let start, let end, let zone) = item.occurrence.time
                else { return }
                let newStart = resize ? start : start.addingTimeInterval(TimeInterval(delta * 60))
                let newEnd = max(
                    newStart.addingTimeInterval(TimeInterval(CalendarStyle.snapMinutes * 60)),
                    end.addingTimeInterval(TimeInterval(delta * 60)))
                if let slot = CalendarSlotValue.slotID(fromUID: event.uid), let moveSlot {
                    moveSlot(slot, newStart, newEnd)
                    return
                }
                let master = event.masterID ?? event.id
                let series = model.event(master)?.recurrence != nil
                _Concurrency.Task {
                    await model.move(
                        eventID: master, occurrenceKey: series ? item.occurrence.key : nil,
                        to: .timed(start: newStart, end: newEnd, timeZone: zone),
                        scope: series ? .occurrence : .series)
                }
            }
    }
}

/// Month view: six weeks of cells with the first events of each day.
struct CalendarMonthGrid: View {
    @ObservedObject var model: CalendarWorkspaceModel
    var openDay: (Date) -> Void

    var body: some View {
        let calendar = model.calendar
        let month = model.period.interval(calendar: calendar)
        let lead = (calendar.component(.weekday, from: month.start) - calendar.firstWeekday + 7) % 7
        let first = calendar.date(byAdding: .day, value: -lead, to: month.start)!
        let days = (0..<42).map { calendar.date(byAdding: .day, value: $0, to: first)! }
        let occurrences = model.shownOccurrences()
        let symbols = (0..<7).map { calendar.shortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7] }
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(symbols, id: \.self) { Text($0.capitalized).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }.frame(height: CalendarStyle.dayHeaderHeight)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let inMonth = month.contains(day)
                    let items = occurrences.filter { calendar.isDate($0.start, inSameDayAs: day) || ($0.start < day && $0.end > day) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(calendar.component(.day, from: day))").font(.caption.weight(calendar.isDateInToday(day) ? .bold : .regular))
                            .foregroundStyle(calendar.isDateInToday(day) ? WorkspaceStyle.accent : inMonth ? .primary : .secondary)
                        ForEach(items.prefix(3), id: \.eventID) { occurrence in
                            HStack(spacing: 4) {
                                Circle().fill(CalendarStyle.color(model.collection(occurrence.collectionID)?.color ?? "")).frame(
                                    width: 6, height: 6)
                                Text(
                                    model.event(occurrence.eventID)?.isBusyCopy == true
                                        ? "Занято" : model.event(occurrence.eventID)?.title ?? ""
                                )
                                .font(.caption2).lineLimit(1)
                            }
                        }
                        if items.count > 3 { Text("ещё \(items.count - 3)").font(.caption2).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                    }
                    .padding(4).frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
                    .border(CalendarStyle.hourLine, width: 0.5)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { openDay(day) }
                }
            }
        }
    }
}
