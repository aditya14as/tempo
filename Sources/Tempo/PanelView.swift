import SwiftUI

struct PanelView: View {
    @EnvironmentObject var store: ConfigStore
    @State private var showSettings = false

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
                TodoSection(now: now)
                footer
            }
            .padding(16)
        }
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
                    Label(dropTargeted ? "Drop to add" : "Add a task — or drop a file here",
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

/// Date + time picker for a task, plus export to the Apple Reminders app.
struct DuePopover: View {
    @EnvironmentObject var store: ConfigStore
    var todoID: UUID
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("Due", selection: dueBinding, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.field)
                .font(.system(.subheadline, design: .rounded))
            Text("Tempo notifies you at this time.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack {
                Button("Clear") {
                    update { $0.dueDate = nil }
                }
                Spacer()
                Button("Add to Apple Reminders") {
                    guard let todo = store.config.todos.first(where: { $0.id == todoID }) else { return }
                    status = "Adding…"
                    AppleReminders.add(todo) { result in
                        status = result
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
        .frame(width: 260)
    }

    private var dueBinding: Binding<Date> {
        Binding {
            store.config.todos.first(where: { $0.id == todoID })?.dueDate ?? Date()
        } set: { date in
            update { $0.dueDate = date }
        }
    }

    private func update(_ change: (inout TodoItem) -> Void) {
        guard let index = store.config.todos.firstIndex(where: { $0.id == todoID }) else { return }
        change(&store.config.todos[index])
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
