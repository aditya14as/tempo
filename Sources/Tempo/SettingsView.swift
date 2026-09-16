import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    var onBack: () -> Void
    @State private var showPerDayHours = false

    private static let dayOrder: [(weekday: Int, chip: String, name: String)] = [
        (2, "M", "Monday"), (3, "T", "Tuesday"), (4, "W", "Wednesday"), (5, "T", "Thursday"),
        (6, "F", "Friday"), (7, "S", "Saturday"), (1, "S", "Sunday"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Settings")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .kerning(1.2)
            }
            .padding(16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Work hours") {
                        HStack {
                            DatePicker("Start", selection: allDaysBinding(\.startMinute), displayedComponents: .hourAndMinute)
                            DatePicker("End", selection: allDaysBinding(\.endMinute), displayedComponents: .hourAndMinute)
                        }
                        .datePickerStyle(.compact)
                        Text("Sets every workday's first slot. Use Per-day hours to split a day into slots.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        HStack(spacing: 6) {
                            ForEach(Self.dayOrder, id: \.weekday) { day in
                                dayChip(day.weekday, day.chip)
                            }
                        }
                        DisclosureGroup(isExpanded: $showPerDayHours) {
                            VStack(spacing: 6) {
                                ForEach(Self.dayOrder, id: \.weekday) { day in
                                    perDayRow(day.weekday, day.name)
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("Per-day hours")
                                .font(.system(.subheadline, design: .rounded))
                        }
                    }

                    section("Rows") {
                        ForEach(Metric.allCases) { metric in
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: rowBinding(metric, \.visible)) {
                                    Text(metric.title)
                                        .font(.system(.subheadline, design: .rounded))
                                }
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                Picker("", selection: rowBinding(metric, \.style)) {
                                    ForEach(RowStyle.allCases) { style in
                                        Text(style.label).tag(style)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .controlSize(.small)
                                .labelsHidden()
                                .disabled(!store.config.row(metric).visible)
                            }
                            .padding(.bottom, 2)
                        }
                    }

                    section("Counting") {
                        basisPicker("Week", selection: $store.config.weekBasis, all: WeekBasis.allCases)
                        basisPicker("Month", selection: $store.config.monthBasis, all: MonthBasis.allCases)
                        basisPicker("Year", selection: $store.config.yearBasis, all: YearBasis.allCases)
                        Text(resolvedSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    section("Menu bar") {
                        labeledRow("Style") {
                            Picker("", selection: $store.config.menuBarStyle) {
                                ForEach(MenuBarStyle.allCases) { s in Text(s.label).tag(s) }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .labelsHidden()
                        }
                        labeledRow("Shows") {
                            Picker("", selection: $store.config.menuBarShows) {
                                ForEach(MenuBarShows.allCases) { m in Text(m.label).tag(m) }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .labelsHidden()
                        }
                    }

                    section("Theme") {
                        HStack(spacing: 10) {
                            ForEach(Theme.allCases) { theme in
                                Button {
                                    store.config.theme = theme
                                } label: {
                                    Circle()
                                        .fill(theme.gradient)
                                        .frame(width: 26, height: 26)
                                        .overlay(
                                            Circle().strokeBorder(
                                                store.config.theme == theme ? Color.primary : .clear,
                                                lineWidth: 2
                                            )
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(theme.label)
                            }
                        }
                    }

                    section("General") {
                        Toggle("Launch at login", isOn: $store.config.launchAtLogin)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        Text("Works when Tempo runs from the built .app.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 360)
    }

    private var resolvedSummary: String {
        let parts = [Metric.week, .month, .year].map { metric in
            "\(metric.title.lowercased()) → \(store.config.resolvedMode(for: metric) == .workHours ? "work hours" : "calendar")"
        }
        return "Right now: " + parts.joined(separator: ", ") + "."
    }

    // MARK: - Small builders

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(1)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func labeledRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(.subheadline, design: .rounded))
                .frame(width: 48, alignment: .leading)
            content()
        }
    }

    private func basisPicker<B: Identifiable & Hashable>(
        _ label: String, selection: Binding<B>, all: [B]
    ) -> some View where B: RawRepresentable, B.RawValue == String {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(.subheadline, design: .rounded))
            Picker("", selection: selection) {
                ForEach(all) { basis in
                    Text(basisLabel(basis)).tag(basis)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
        }
    }

    private func basisLabel<B>(_ basis: B) -> String {
        if let b = basis as? WeekBasis { return b.label }
        if let b = basis as? MonthBasis { return b.label }
        if let b = basis as? YearBasis { return b.label }
        return ""
    }

    private func dayChip(_ weekday: Int, _ label: String) -> some View {
        let selected = store.config.schedule.day(weekday).enabled
        return Button {
            var schedule = store.config.schedule
            var day = schedule.day(weekday)
            if day.enabled {
                guard schedule.enabledCount > 1 else { return }  // keep at least one workday
                day.enabled = false
            } else {
                day.enabled = true
            }
            schedule.setDay(weekday, day)
            store.config.schedule = schedule
        } label: {
            Text(label)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(selected ? AnyShapeStyle(store.config.theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
                )
                .foregroundStyle(selected ? .white : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func perDayRow(_ weekday: Int, _ name: String) -> some View {
        let day = store.config.schedule.day(weekday)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(day.slots.enumerated()), id: \.element.id) { index, _ in
                HStack(spacing: 8) {
                    Text(index == 0 ? name : "")
                        .font(.system(.caption, design: .rounded))
                        .frame(width: 60, alignment: .leading)
                        .foregroundStyle(day.enabled ? .primary : .tertiary)
                    DatePicker("", selection: slotMinuteBinding(weekday, index, \.startMinute), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Text("–").foregroundStyle(.tertiary)
                    DatePicker("", selection: slotMinuteBinding(weekday, index, \.endMinute), displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    Spacer(minLength: 0)
                    if index == 0 {
                        Button { addSlot(weekday) } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(day.slots.count >= Self.maxSlots)
                        .help("Split this day: add another time slot")
                    } else {
                        Button { removeSlot(weekday, index) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove this slot")
                    }
                }
            }
        }
        .disabled(!day.enabled)
        .opacity(day.enabled ? 1 : 0.5)
    }

    private static let maxSlots = 4

    private func addSlot(_ weekday: Int) {
        var schedule = store.config.schedule
        var day = schedule.day(weekday)
        guard day.slots.count < Self.maxSlots else { return }
        let lastEnd = day.slots.map(\.endMinute).max() ?? 18 * 60
        let start = min(lastEnd + 60, 23 * 60)
        day.slots.append(WorkSlot(startMinute: start, endMinute: min(start + 60, 24 * 60)))
        schedule.setDay(weekday, day)
        store.config.schedule = schedule
    }

    private func removeSlot(_ weekday: Int, _ index: Int) {
        var schedule = store.config.schedule
        var day = schedule.day(weekday)
        guard day.slots.indices.contains(index), day.slots.count > 1 else { return }
        day.slots.remove(at: index)
        schedule.setDay(weekday, day)
        store.config.schedule = schedule
    }

    // MARK: - Bindings

    private static func dateFrom(minutes: Int) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: cal.startOfDay(for: Date())) ?? Date()
    }

    private static func minutesFrom(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Keeps a slot valid after an edit: end must stay after start.
    private static func validated(_ slot: WorkSlot, changed keyPath: WritableKeyPath<WorkSlot, Int>) -> WorkSlot {
        var slot = slot
        if slot.endMinute <= slot.startMinute {
            if keyPath == \.startMinute {
                slot.endMinute = min(slot.startMinute + 60, 24 * 60)
            } else {
                slot.startMinute = max(slot.endMinute - 60, 0)
            }
        }
        return slot
    }

    /// Edits one slot's start or end time on one weekday.
    private func slotMinuteBinding(_ weekday: Int, _ index: Int, _ keyPath: WritableKeyPath<WorkSlot, Int>) -> Binding<Date> {
        Binding {
            let slots = store.config.schedule.day(weekday).slots
            guard slots.indices.contains(index) else { return Self.dateFrom(minutes: 10 * 60) }
            return Self.dateFrom(minutes: slots[index][keyPath: keyPath])
        } set: { date in
            var schedule = store.config.schedule
            var day = schedule.day(weekday)
            guard day.slots.indices.contains(index) else { return }
            var slot = day.slots[index]
            slot[keyPath: keyPath] = Self.minutesFrom(date)
            day.slots[index] = Self.validated(slot, changed: keyPath)
            schedule.setDay(weekday, day)
            store.config.schedule = schedule
        }
    }

    /// Edits every day's first slot at once (shows Monday's value).
    private func allDaysBinding(_ keyPath: WritableKeyPath<WorkSlot, Int>) -> Binding<Date> {
        Binding {
            Self.dateFrom(minutes: store.config.schedule.day(2).slots.first?[keyPath: keyPath] ?? 10 * 60)
        } set: { date in
            let minutes = Self.minutesFrom(date)
            var schedule = store.config.schedule
            for weekday in 1...7 {
                var day = schedule.day(weekday)
                guard var slot = day.slots.first else { continue }
                slot[keyPath: keyPath] = minutes
                day.slots[0] = Self.validated(slot, changed: keyPath)
                schedule.setDay(weekday, day)
            }
            store.config.schedule = schedule
        }
    }

    private func rowBinding<T>(_ metric: Metric, _ keyPath: WritableKeyPath<RowConfig, T>) -> Binding<T> {
        Binding {
            store.config.row(metric)[keyPath: keyPath]
        } set: { value in
            var row = store.config.row(metric)
            row[keyPath: keyPath] = value
            store.config.setRow(metric, row)
        }
    }
}
