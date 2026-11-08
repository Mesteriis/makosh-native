import MakoshCalendar
import SwiftUI

/// Left column: a month, the summary row, accounts with their calendars, groups.
struct CalendarSidebar: View {
    @ObservedObject var model: CalendarWorkspaceModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CalendarMiniMonth(model: model)
                summaryRow
                if let snapshot = model.snapshot {
                    ForEach(snapshot.accounts.filter { $0.state != .disabled }) { account in
                        accountSection(account, snapshot: snapshot)
                    }
                    groups(snapshot)
                }
                Button {
                    UserDefaults.standard.set(MakoshSettingsTab.calendar, forKey: MakoshSettingsTab.key)
                    openSettings()
                } label: {
                    Label("Учётные записи и группы…", systemImage: "gearshape")
                }.buttonStyle(.borderless).accessibilityIdentifier("calendar.sidebar.settings")
            }.padding(14)
        }
    }

    private var summaryRow: some View {
        Button {
            model.select(collectionID: nil)
        } label: {
            HStack {
                Image(systemName: "square.stack.3d.up")
                Text("Сводный вид").fontWeight(model.selectedCollectionID == nil ? .semibold : .regular)
                Spacer()
            }.padding(.vertical, 5).padding(.horizontal, 8)
                .background(
                    model.selectedCollectionID == nil ? WorkspaceStyle.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityIdentifier("calendar.sidebar.summary")
    }

    private func accountSection(_ account: CalendarAccount, snapshot: CalendarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(account.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).lineLimit(1)
                Spacer()
                stateIcon(account.state)
            }
            ForEach(snapshot.collections.filter { $0.accountID == account.id }) { collection in
                collectionRow(collection, snapshot: snapshot)
            }
        }
    }

    @ViewBuilder private func stateIcon(_ state: CalendarAccountState) -> some View {
        switch state {
        case .needsSignIn: Image(systemName: "key.slash").foregroundStyle(.orange).help("Нужно войти снова")
        case .adminBlocked: Image(systemName: "hand.raised").foregroundStyle(.red).help("Администратор запретил доступ")
        case .unreachable:
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.yellow).help("Сервер недоступен: плашки не обновляются")
        case .connected, .disabled: EmptyView()
        }
    }

    private func collectionRow(_ collection: CalendarCollection, snapshot: CalendarSnapshot) -> some View {
        HStack(spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { collection.shown },
                    set: { value in _Concurrency.Task { await model.setShown(collectionID: collection.id, value) } })
            ).toggleStyle(.checkbox).labelsHidden().help("Показывать в сводном виде")
            Circle().fill(CalendarStyle.color(collection.color)).frame(width: 9, height: 9)
            Button {
                model.select(collectionID: collection.id)
            } label: {
                Text(collection.name).lineLimit(1).fontWeight(model.selectedCollectionID == collection.id ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).help("Открыть календарь с плашками и рабочим днём")
            if snapshot.staleCollectionIDs.contains(collection.id) {
                Image(systemName: "exclamationmark.triangle").font(.caption).foregroundStyle(.yellow).help(
                    "Занятость в этом календаре не обновляется")
            }
            ForEach(snapshot.groups.filter { collection.groupIDs.contains($0.id) }) { group in
                Text(group.name).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(WorkspaceStyle.accent.opacity(0.18), in: Capsule()).foregroundStyle(WorkspaceStyle.accent)
            }
            if collection.access == .read { Image(systemName: "lock").font(.caption2).foregroundStyle(.secondary).help("Только чтение") }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(
            model.selectedCollectionID == collection.id ? WorkspaceStyle.accent.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .accessibilityIdentifier("calendar.sidebar.collection")
    }

    private func groups(_ snapshot: CalendarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Группы занятости").font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            if snapshot.groups.isEmpty {
                Text("Нет групп. Объедините календари в Настройках, чтобы события давали «Занято» в соседних календарях.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.groups) { group in
                HStack {
                    Image(systemName: "link")
                    Text(group.name)
                    Spacer()
                    Text("\(snapshot.collections.filter { $0.groupIDs.contains(group.id) }.count)").foregroundStyle(.secondary)
                }.font(.callout)
            }
        }
    }
}

/// A small month for jumping to a day.
struct CalendarMiniMonth: View {
    @ObservedObject var model: CalendarWorkspaceModel

    var body: some View {
        let calendar = model.calendar
        let month = CalendarPeriod(mode: .month, anchor: model.period.anchor)
        let days = month.days(calendar: calendar)
        let lead = (calendar.component(.weekday, from: days.first ?? Date()) - calendar.firstWeekday + 7) % 7
        let symbols = (0..<7).map { calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + $0) % 7] }
        VStack(spacing: 6) {
            HStack {
                Text(DateFormatter.calendar("LLLLyyyy").string(from: model.period.anchor).capitalized).font(.headline)
                Spacer()
                Button {
                    model.period = month.moved(by: -1, calendar: calendar).withMode(model.period.mode)
                    refresh()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Button {
                    model.period = month.moved(by: 1, calendar: calendar).withMode(model.period.mode)
                    refresh()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(symbols.indices, id: \.self) { Text(symbols[$0]).font(.caption2).foregroundStyle(.secondary) }
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 22) }
                ForEach(days, id: \.self) { day in
                    let selected = calendar.isDate(day, inSameDayAs: model.period.anchor)
                    Button {
                        model.period = CalendarPeriod(mode: model.period.mode, anchor: day)
                        refresh()
                    } label: {
                        Text("\(calendar.component(.day, from: day))").font(.caption).frame(maxWidth: .infinity, minHeight: 22)
                            .background(
                                selected
                                    ? WorkspaceStyle.accent.opacity(0.35) : calendar.isDateInToday(day) ? CalendarStyle.todayTint : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func refresh() { _Concurrency.Task { await model.refresh() } }
}

extension CalendarPeriod {
    func withMode(_ mode: CalendarViewMode) -> CalendarPeriod { CalendarPeriod(mode: mode, anchor: anchor) }
}
