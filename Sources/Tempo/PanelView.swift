import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case now, tasks, week, awake, clipboard

    var id: String { rawValue }
    var label: String {
        switch self {
        case .now: return "Now"
        case .tasks: return "Tasks"
        case .week: return "Week"
        case .awake: return "Awake"
        case .clipboard: return "Clips"
        }
    }
    /// The feature that owns this tab.
    var feature: Feature {
        switch self {
        case .now: return .workHours
        case .tasks, .week: return .tasks
        case .awake: return .awake
        case .clipboard: return .clipboard
        }
    }
    var icon: String {
        switch self {
        case .now: return "gauge.with.needle"
        case .tasks: return "checklist"
        case .week: return "calendar"
        case .awake: return "bolt.fill"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

/// Lets other parts of Tempo (the clipboard popup's "Settings…") open the
/// dropdown straight on Settings. The dropdown may not exist yet when asked,
/// so the request is kept until the panel appears.
@MainActor
enum PanelRequest {
    static var settings = false
    static let changed = Notification.Name("tempo.panelRequest")

    static func openSettings() {
        settings = true
        NotificationCenter.default.post(name: changed, object: nil)
    }
}

struct PanelView: View {
    @EnvironmentObject var store: ConfigStore
    @ViewState private var showSettings = false
    @ViewState private var tab: PanelTab = .now

    var body: some View {
        Group {
            if showSettings {
                SettingsView(onBack: { withAnimation(.easeInOut(duration: 0.2)) { showSettings = false } },
                             highlightFeatures: visibleTabs.isEmpty)
            } else {
                progressContent
            }
        }
        .frame(width: 360)
        // Settings → Appearance → Background: more solid reads better over
        // busy windows behind the dropdown's glass.
        .background(Color(nsColor: .windowBackgroundColor).opacity(store.config.backgroundOpacity))
        .onAppear(perform: takeRequest)
        .onReceive(NotificationCenter.default.publisher(for: PanelRequest.changed)) { _ in takeRequest() }
        // Hand our window and laid-out size to PanelAligner so it can keep
        // the dropdown fitted to the content and hugging the menu bar icon —
        // the MenuBarExtra window otherwise keeps the first tab's height
        // forever and floats shorter tabs in the middle of it.
        .background(PanelWindowTracker())
    }

    private var progressContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let config = store.config
            let tabs = visibleTabs
            let current = tabs.contains(tab) ? tab : tabs.first
            VStack(alignment: .leading, spacing: 14) {
                header(now: now)
                if tabs.count > 1 { tabBar(tabs, current: current) }
                if current == tabs.first { SetupCard() }
                switch current {
                case nil:
                    NoTabsCard { withAnimation(.easeInOut(duration: 0.2)) { showSettings = true } }
                case .now:
                    ForEach(Metric.allCases) { metric in
                        if config.row(metric).visible {
                            MetricRowView(
                                metric: metric,
                                snapshot: ProgressEngine.snapshot(metric, now: now, config: config),
                                style: config.row(metric).style,
                                theme: config.theme,
                                config: config,
                                now: now
                            )
                        }
                    }
                case .tasks:
                    TodoSection(now: now)
                case .week:
                    WeekGlance(now: now)
                case .awake:
                    AwakeTab(now: now)
                case .clipboard:
                    ClipboardTab()
                }
                footer
            }
            .padding(16)
        }
        // Opening the panel pulls done-state back from the Reminders app
        // and clears "+" rows that were never filled in.
        .onAppear {
            store.tidyTodos()
            store.pullAppleReminderCompletions()
            // Keep the menu bar icon's drop zone alive even if the
            // status item was rebuilt (e.g. after a style change).
            StatusItemDropper.install()
        }
    }

    private func takeRequest() {
        guard PanelRequest.settings else { return }
        PanelRequest.settings = false
        showSettings = true
    }

    /// Tabs for the features that are switched on, in their usual order.
    private var visibleTabs: [PanelTab] {
        PanelTab.allCases.filter { store.config.isOn($0.feature) }
    }

    private func tabBar(_ tabs: [PanelTab], current: PanelTab?) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: t.icon).font(.system(size: 10))
                        Text(t.label)
                    }
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(
                        Capsule().fill(current == t
                            ? AnyShapeStyle(store.config.theme.gradient)
                            : AnyShapeStyle(Color.clear))
                    )
                    .foregroundStyle(current == t ? .white : .secondary)
                    // Transparent areas don't hit-test; make the whole pill clickable.
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.045)))
    }

    private func header(now: Date) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .font(.system(.headline, design: .rounded))
                Text("Tempo")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .kerning(1.2)
            }
            Spacer()
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(.subheadline, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSettings = true }
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")

            if store.config.features.shelf {
                Button {
                    ShelfWindow.shared.toggle(store: store)
                } label: {
                    Image(systemName: "tray.full.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .help("Shelf — a floating drop zone for files")
            }

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quit Tempo")
        }
        .padding(.top, 2)
    }
}

/// Shown when every feature with a tab is switched off.
struct NoTabsCard: View {
    @EnvironmentObject var store: ConfigStore
    var openSettings: () -> Void

    var body: some View {
        let config = store.config
        let background = [Feature.switcher, .shelf].filter { config.isOn($0) }
        VStack(alignment: .leading, spacing: 10) {
            if background.isEmpty {
                Text("Every feature is off")
                    .font(.system(.headline, design: .rounded))
                Text("Pick what Tempo should do for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Working in the background")
                    .font(.system(.headline, design: .rounded))
                ForEach(background) { feature in
                    HStack(spacing: 8) {
                        FeatureIcon(feature: feature, theme: config.theme, size: 22)
                        Text(feature == .switcher
                            ? "Hold \(config.switcher.modifier.symbol) and press ⇥ to switch windows"
                            : "Start dragging a file and the Shelf pops up")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button(action: openSettings) {
                Label("Choose features", systemImage: "square.grid.2x2.fill")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(config.theme.gradient))
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

/// Due picker: one-tap presets, a real calendar, a time stepper,
/// and export to the Apple Reminders app.
struct DuePopover: View {
    @EnvironmentObject var store: ConfigStore
    var todoID: UUID
    @ViewState private var status: String?

    private var cal: Calendar { Calendar.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remind me")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(1)
            HStack(spacing: 6) {
                quickChip("In 2h") { QuickDue.inTwoHours($0, cal: cal) }
                quickChip("Tonight") { QuickDue.tonight($0, cal: cal) }
                quickChip("Tomorrow") { QuickDue.tomorrowMorning($0, schedule: store.config.schedule, cal: cal) }
                quickChip("Next Mon") { QuickDue.nextMonday($0, schedule: store.config.schedule, cal: cal) }
            }
            DatePicker("", selection: dayBinding, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Text("At")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.stepperField)
                    .labelsHidden()
                Spacer()
                if let due = currentDue {
                    Text(DueFormat.label(due, now: Date(), cal: cal))
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(store.config.theme.gradient)
                }
            }
            Divider()
            HStack {
                Button("Clear") {
                    update { $0.dueDate = nil }
                }
                Spacer()
                Button("Add to Apple Reminders") {
                    guard let todo = store.config.todos.first(where: { $0.id == todoID }) else { return }
                    status = "Adding…"
                    AppleReminders.add(todo) { result, reminderID in
                        status = result
                        if let reminderID {
                            update { $0.reminderID = reminderID }
                        }
                    }
                }
            }
            .controlSize(.small)
            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func quickChip(_ label: String, _ make: @escaping (Date) -> Date) -> some View {
        let due = make(Date())
        let selected = currentDue.map { abs($0.timeIntervalSince(due)) < 60 } ?? false
        return Button {
            update { $0.dueDate = make(Date()) }
        } label: {
            Text(label)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected
                        ? AnyShapeStyle(store.config.theme.gradient)
                        : AnyShapeStyle(Color.primary.opacity(0.07)))
                )
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var currentDue: Date? {
        store.config.todos.first(where: { $0.id == todoID })?.dueDate
    }

    /// Calendar picks the day; the task's time of day is kept.
    private var dayBinding: Binding<Date> {
        Binding {
            currentDue ?? Date()
        } set: { picked in
            let old = currentDue ?? Date()
            let time = cal.dateComponents([.hour, .minute], from: old)
            var merged = cal.dateComponents([.year, .month, .day], from: picked)
            merged.hour = time.hour
            merged.minute = time.minute
            update { $0.dueDate = cal.date(from: merged) ?? picked }
        }
    }

    /// Stepper picks the time; the task's day is kept.
    private var timeBinding: Binding<Date> {
        Binding {
            currentDue ?? Date()
        } set: { picked in
            let old = currentDue ?? Date()
            var merged = cal.dateComponents([.year, .month, .day], from: old)
            let time = cal.dateComponents([.hour, .minute], from: picked)
            merged.hour = time.hour
            merged.minute = time.minute
            update { $0.dueDate = cal.date(from: merged) ?? picked }
        }
    }

    private func update(_ change: (inout TodoItem) -> Void) {
        guard let index = store.config.todos.firstIndex(where: { $0.id == todoID }) else { return }
        change(&store.config.todos[index])
    }
}

/// This week + next week at a glance: tasks sit on their due day.
/// Click a day to see just that day's tasks; click again to show all.
struct WeekGlance: View {
    @EnvironmentObject var store: ConfigStore
    var now: Date
    @ViewState private var selectedDay: Date?
    @ViewState private var agendaHeight: CGFloat = 0

    private static let maxAgendaHeight: CGFloat = 260

    private var cal: Calendar { ProgressEngine.mondayCalendar }

    var body: some View {
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        VStack(alignment: .leading, spacing: 12) {
            weekRow("This week", start: weekStart)
            weekRow("Next week", start: cal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart)
            agenda
        }
    }

    private func weekRow(_ title: String, start: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(1)
            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { offset in
                    dayCell(cal.date(byAdding: .day, value: offset, to: start) ?? start)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func dayCell(_ day: Date) -> some View {
        let tasks = DueFormat.tasks(store.config.todos, dueOn: day, cal: cal)
        let isToday = cal.isDate(day, inSameDayAs: now)
        let isSelected = selectedDay.map { cal.isDate(day, inSameDayAs: $0) } ?? false
        let hasOverdue = tasks.contains { DueFormat.isOverdue($0.dueDate ?? now, now: now, done: $0.done) }
        let weekdayIndex = (cal.component(.weekday, from: day) + 5) % 7  // 0 = Monday
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedDay = isSelected ? nil : day
            }
        } label: {
            VStack(spacing: 3) {
            Text(letters[weekdayIndex])
                .font(.system(size: 8, design: .rounded).weight(.bold))
                .foregroundStyle(.tertiary)
            Text("\(cal.component(.day, from: day))")
                .font(.system(.caption, design: .rounded).weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? .primary : .secondary)
            HStack(spacing: 2) {
                if tasks.isEmpty {
                    Circle().fill(Color.clear).frame(width: 4, height: 4)
                } else {
                    ForEach(tasks.prefix(3)) { task in
                        Circle()
                            .fill(task.done
                                ? AnyShapeStyle(Color.secondary.opacity(0.4))
                                : hasOverdue && DueFormat.isOverdue(task.dueDate ?? now, now: now, done: task.done)
                                    ? AnyShapeStyle(Color.red)
                                    : AnyShapeStyle(store.config.theme.gradient))
                            .frame(width: 4, height: 4)
                    }
                    if tasks.count > 3 {
                        Text("+\(tasks.count - 3)")
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
        }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isToday || isSelected ? Color.primary.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected ? AnyShapeStyle(store.config.theme.gradient)
                            : isToday ? AnyShapeStyle(Color.secondary.opacity(0.5))
                            : AnyShapeStyle(Color.clear),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var agenda: some View {
        // Done tasks only clutter the overview; a selected day shows them all.
        let dated = selectedDay.map { DueFormat.tasks(store.config.todos, dueOn: $0, cal: cal) }
            ?? DueFormat.agenda(store.config.todos).filter { !$0.done }
        if let day = selectedDay {
            HStack {
                Text(DueFormat.label(day, now: now, cal: cal).replacingOccurrences(of: " 00:00", with: ""))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                Spacer()
                Button("Show all") {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedDay = nil }
                }
                .buttonStyle(.plain)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
        if dated.isEmpty {
            Text(selectedDay == nil
                ? "Nothing coming up. Give a task a due time in the Tasks tab and it lands here."
                : "Nothing due this day.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        } else {
            ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(dated) { task in
                    let due = task.dueDate ?? now
                    let overdue = DueFormat.isOverdue(due, now: now, done: task.done)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(task.done
                                ? AnyShapeStyle(Color.secondary.opacity(0.4))
                                : overdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(store.config.theme.gradient))
                            .frame(width: 6, height: 6)
                        Text(task.text.isEmpty ? "Untitled" : task.text)
                            .font(.system(.caption, design: .rounded))
                            .strikethrough(task.done)
                            .foregroundStyle(task.done ? .secondary : .primary)
                            .lineLimit(1)
                        Spacer()
                        Text(DueFormat.label(due, now: now, cal: cal))
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(overdue ? .red : .secondary)
                    }
                }
            }
            .padding(12)
            .measuringHeight($agendaHeight)
            }
            .frame(height: min(max(agendaHeight, 1), Self.maxAgendaHeight))
            .scrollIndicators(agendaHeight > Self.maxAgendaHeight ? .automatic : .never)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        }
    }
}

struct MetricRowView: View {
    var metric: Metric
    var snapshot: MetricSnapshot
    var style: RowStyle
    var theme: Theme
    var config: AppConfig
    var now: Date

    private var dotCount: Int {
        let cal = ProgressEngine.mondayCalendar
        switch metric {
        case .today:
            let day = ProgressEngine.daySchedule(for: now, schedule: config.schedule, cal: cal)
            return day.seconds > 0 ? min(max(Int((day.seconds / 3600).rounded()), 1), 24) : 8
        case .week:
            return min(config.schedule.weekHours, 60)
        case .month:
            return cal.range(of: .day, in: .month, for: now)?.count ?? 30
        case .year:
            return 52
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch style {
            case .percent:
                HStack(alignment: .center) {
                    titleBlock
                    Spacer()
                    BigPercent(fraction: snapshot.fraction, theme: theme)
                }
            case .bar:
                HStack(alignment: .firstTextBaseline) {
                    titleBlock
                    Spacer()
                    BigPercent(fraction: snapshot.fraction, theme: theme, size: 15)
                }
                GradientBar(fraction: snapshot.fraction ?? 0, theme: theme)
                    .opacity(snapshot.fraction == nil ? 0.4 : 1)
            case .ring:
                HStack(spacing: 12) {
                    GradientRing(fraction: snapshot.fraction ?? 0, theme: theme)
                        .opacity(snapshot.fraction == nil ? 0.4 : 1)
                    titleBlock
                    Spacer()
                }
            case .dots:
                HStack(alignment: .firstTextBaseline) {
                    titleBlock
                    Spacer()
                    BigPercent(fraction: snapshot.fraction, theme: theme, size: 15)
                }
                DotGrid(fraction: snapshot.fraction ?? 0, count: dotCount, theme: theme)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
            Text(snapshot.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
