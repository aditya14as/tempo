import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: ConfigStore
    var onBack: () -> Void

    private static let dayLabels: [(weekday: Int, label: String)] = [
        (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"), (1, "S"),
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
                            DatePicker("Start", selection: minuteBinding(\.startMinute), displayedComponents: .hourAndMinute)
                            DatePicker("End", selection: minuteBinding(\.endMinute), displayedComponents: .hourAndMinute)
                        }
                        .datePickerStyle(.compact)
                        HStack(spacing: 6) {
                            ForEach(Self.dayLabels, id: \.weekday) { day in
                                dayChip(day.weekday, day.label)
                            }
                        }
                    }

                    section("Rows") {
                        ForEach(Metric.allCases) { metric in
                            HStack {
                                Toggle(isOn: rowBinding(metric, \.visible)) {
                                    Text(metric.title)
                                        .font(.system(.subheadline, design: .rounded))
                                }
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                Spacer()
                                Picker("", selection: rowBinding(metric, \.style)) {
                                    ForEach(RowStyle.allCases) { style in
                                        Text(style.label).tag(style)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 150)
                                .disabled(!store.config.row(metric).visible)
                            }
                        }
                    }

                    section("Counting mode") {
                        modePicker("Month", $store.config.monthMode)
                        modePicker("Year", $store.config.yearMode)
                    }

                    section("Menu bar") {
                        labeledPicker("Style") {
                            Picker("", selection: $store.config.menuBarStyle) {
                                ForEach(MenuBarStyle.allCases) { s in Text(s.label).tag(s) }
                            }
                            .pickerStyle(.segmented)
                        }
                        labeledPicker("Shows") {
                            Picker("", selection: $store.config.menuBarMetric) {
                                ForEach(Metric.allCases) { m in Text(m.title).tag(m) }
                            }
                            .pickerStyle(.segmented)
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
        .frame(width: 324)
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

    private func labeledPicker(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(.subheadline, design: .rounded))
                .frame(width: 48, alignment: .leading)
            content()
        }
    }

    private func modePicker(_ label: String, _ binding: Binding<ProgressMode>) -> some View {
        labeledPicker(label) {
            Picker("", selection: binding) {
                ForEach(ProgressMode.allCases) { mode in Text(mode.label).tag(mode) }
            }
            .pickerStyle(.segmented)
        }
    }

    private func dayChip(_ weekday: Int, _ label: String) -> some View {
        let selected = store.config.schedule.workdays.contains(weekday)
        return Button {
            var days = store.config.schedule.workdays
            if selected {
                if days.count > 1 { days.remove(weekday) }  // keep at least one workday
            } else {
                days.insert(weekday)
            }
            store.config.schedule.workdays = days
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

    /// Bridges a minutes-from-midnight Int to a Date for DatePicker.
    private func minuteBinding(_ keyPath: WritableKeyPath<WorkSchedule, Int>) -> Binding<Date> {
        Binding {
            let minutes = store.config.schedule[keyPath: keyPath]
            let cal = Calendar.current
            return cal.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: cal.startOfDay(for: Date())) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            var schedule = store.config.schedule
            schedule[keyPath: keyPath] = minutes
            // Keep the window valid: end must stay after start.
            if schedule.endMinute <= schedule.startMinute {
                if keyPath == \.startMinute {
                    schedule.endMinute = min(schedule.startMinute + 60, 24 * 60)
                } else {
                    schedule.startMinute = max(schedule.endMinute - 60, 0)
                }
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
