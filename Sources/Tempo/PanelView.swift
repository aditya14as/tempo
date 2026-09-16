import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case now, tasks, week

    var id: String { rawValue }
    var label: String {
        switch self {
        case .now: return "Now"
        case .tasks: return "Tasks"
        case .week: return "Week"
        }
    }
    var icon: String {
        switch self {
        case .now: return "gauge.with.needle"
        case .tasks: return "checklist"
        case .week: return "calendar"
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var showSettings = false
    @State private var tab: PanelTab = .now

    var body: some View {
        Group {
            if showSettings {
                SettingsView(onBack: { withAnimation(.easeInOut(duration: 0.2)) { showSettings = false } })
            } else {
                progressContent
            }
        }
        .frame(width: 360)
    }

    private var progressContent: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let config = store.config
            VStack(alignment: .leading, spacing: 14) {
                header(now: now)
                tabBar
                switch tab {
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
                }
                footer
            }
            .padding(16)
        }
        // Opening the panel pulls done-state back from the Reminders app.
        .onAppear { store.pullAppleReminderCompletions() }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(PanelTab.allCases) { t in
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
                        Capsule().fill(tab == t
                            ? AnyShapeStyle(store.config.theme.gradient)
                            : AnyShapeStyle(Color.clear))
                    )
                    .foregroundStyle(tab == t ? .white : .secondary)
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

            Button {
                ShelfWindow.shared.toggle(store: store)
            } label: {
                Image(systemName: "tray.full.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
            .help("Shelf — a floating drop zone for files")

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

/// Up to 5 focus tasks with optional due-time reminders and file attachments.
/// Files/links can be dropped here from Finder, VS Code, or a browser.
struct TodoSection: View {
    @EnvironmentObject var store: ConfigStore
    var now: Date
    @State private var duePopover: UUID?
    @State private var dropTargeted = false

    var body: some View {
        let todos = store.config.todos
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Top 5")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                Spacer()
                if !todos.isEmpty {
                    Text("\(todos.filter(\.done).count)/\(todos.count) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ForEach(todos) { todo in
                todoRow(todo)
            }
            if todos.count < AppConfig.maxTodos {
                Button {
                    store.config.todos.append(TodoItem(text: ""))
                } label: {
                    Label(dropTargeted ? "Drop to add" : "Add a task — for file drops, open the Shelf (tray icon below)",
                          systemImage: dropTargeted ? "arrow.down.circle" : "plus")
                        .font(.system(.caption, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(dropTargeted ? 0.09 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    dropTargeted ? AnyShapeStyle(store.config.theme.gradient) : AnyShapeStyle(Color.clear),
                    lineWidth: 1.5
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            addDropped(urls)
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
    }

    private func todoRow(_ todo: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Button {
                    update(todo.id) { $0.done.toggle() }
                } label: {
                    Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(todo.done
                            ? AnyShapeStyle(store.config.theme.gradient)
                            : AnyShapeStyle(Color.secondary))
                }
                .buttonStyle(.plain)
                TextField("What matters today?", text: textBinding(todo.id))
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(todo.done ? .secondary : .primary)
                Button {
                    openDuePopover(todo)
                } label: {
                    Image(systemName: todo.dueDate == nil ? "clock" : "clock.fill")
                        .foregroundStyle(todo.dueDate == nil ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(store.config.theme.gradient))
                }
                .buttonStyle(.plain)
                .help("Due time & reminder")
                .popover(isPresented: popoverBinding(todo.id), arrowEdge: .bottom) {
                    DuePopover(todoID: todo.id)
                        .environmentObject(store)
                }
                Button {
                    store.config.todos.removeAll { $0.id == todo.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
            if todo.dueDate != nil || todo.linkName != nil {
                HStack(spacing: 6) {
                    if let due = todo.dueDate {
                        let overdue = DueFormat.isOverdue(due, now: now, done: todo.done)
                        chip(
                            icon: overdue ? "exclamationmark.circle" : "bell",
                            text: (overdue ? "Overdue · " : "") + DueFormat.label(due, now: now),
                            tint: overdue ? .red : .secondary
                        )
                    }
                    if let name = todo.linkName {
                        Button {
                            if let url = todo.linkURL { NSWorkspace.shared.open(url) }
                        } label: {
                            chip(icon: "paperclip", text: name, tint: .secondary)
                        }
                        .buttonStyle(.plain)
                        .onDrag {
                            if let link = todo.link, link.hasPrefix("/"),
                                let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: link)) {
                                return provider
                            }
                            if let url = todo.linkURL { return NSItemProvider(object: url as NSURL) }
                            return NSItemProvider()
                        }
                        .help(todo.link ?? "")
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private func chip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).lineLimit(1)
        }
        .font(.system(.caption2, design: .rounded))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    /// Turns each dropped file/link into a task, up to the 5-task cap.
    @discardableResult
    private func addDropped(_ urls: [URL]) -> Bool {
        let free = AppConfig.maxTodos - store.config.todos.count
        guard free > 0, !urls.isEmpty else { return false }
        store.config.todos.append(contentsOf: urls.prefix(free).map(TodoItem.fromDroppedURL))
        return true
    }

    private func openDuePopover(_ todo: TodoItem) {
        if todo.dueDate == nil {
            // Seed with the next full hour so the picker starts somewhere sane.
            let cal = Calendar.current
            let nextHour = cal.date(bySetting: .minute, value: 0, of: now.addingTimeInterval(3600)) ?? now
            update(todo.id) { $0.dueDate = nextHour }
        }
        duePopover = todo.id
    }

    private func popoverBinding(_ id: UUID) -> Binding<Bool> {
        Binding {
            duePopover == id
        } set: { open in
            if !open { duePopover = nil }
        }
    }

    private func update(_ id: UUID, _ change: (inout TodoItem) -> Void) {
        guard let index = store.config.todos.firstIndex(where: { $0.id == id }) else { return }
        change(&store.config.todos[index])
    }

    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding {
            store.config.todos.first(where: { $0.id == id })?.text ?? ""
        } set: { text in
            update(id) { $0.text = text }
        }
    }
}

/// Due picker: one-tap presets, a real calendar, a time stepper,
/// and export to the Apple Reminders app.
struct DuePopover: View {
    @EnvironmentObject var store: ConfigStore
    var todoID: UUID
    @State private var status: String?

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
    @State private var selectedDay: Date?

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
        let dated = selectedDay.map { DueFormat.tasks(store.config.todos, dueOn: $0, cal: cal) }
            ?? DueFormat.agenda(store.config.todos)
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
                ? "No dated tasks yet. Give a task a due time in the Tasks tab and it lands here."
                : "Nothing due this day.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        } else {
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
