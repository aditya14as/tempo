import SwiftUI
import UniformTypeIdentifiers

// MARK: - Measuring (scrollable lists in the content-sized dropdown)

/// Carries a laid-out height up to `measuringHeight`.
struct MeasuredHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Reports this view's laid-out height into `height`. The dropdown is sized
    /// exactly to its content, so a ScrollView needs an explicit height:
    /// measure what's inside and cap it, e.g. `.frame(height: min(h, 320))`.
    func measuringHeight(_ height: Binding<CGFloat>) -> some View {
        background(GeometryReader { geo in
            Color.clear.preference(key: MeasuredHeightKey.self, value: geo.size.height)
        })
        .onPreferenceChange(MeasuredHeightKey.self) { value in
            MainActor.assumeIsolated {
                if abs(height.wrappedValue - value) > 0.5 { height.wrappedValue = value }
            }
        }
        // Don't leak this measurement into an outer one.
        .transformPreference(MeasuredHeightKey.self) { $0 = 0 }
    }
}

// MARK: - Tasks tab

/// Checked tasks wait here for a beat (so the strikethrough shows) before
/// they move to Completed. Lives outside the view so closing the dropdown
/// mid-wait still completes them.
@MainActor
private enum PendingCompletions {
    static var ids: Set<UUID> = []
}

/// What the Undo pill puts back: removed tasks with their old positions.
private struct TaskUndo {
    let id = UUID()
    var removed: [(index: Int, item: TodoItem)]
    var label: String
}

/// The task list: quick add on top, a scrolling list grouped by due date,
/// a collapsible Completed section, due reminders and file attachments.
/// Files/links can be dropped here from Finder, VS Code, or a browser.
struct TodoSection: View {
    @EnvironmentObject var store: ConfigStore
    var now: Date

    @ViewState private var draft = ""
    @FocusState private var addFocused: Bool
    @FocusState private var notesFocused: Bool
    @ViewState private var dropTargeted = false
    @ViewState private var duePopover: UUID?
    @ViewState private var justCompleted: Set<UUID> = []
    @ViewState private var editingNotes: UUID?
    @ViewState private var reorderTarget: UUID?
    @ViewState private var hovered: UUID?
    @ViewState private var undo: TaskUndo?
    @ViewState private var listHeight: CGFloat = 0
    @ViewState private var scrollTarget: UUID?

    private static let maxListHeight: CGFloat = 320
    private var cal: Calendar { Calendar.current }
    private var theme: Theme { store.config.theme }

    var body: some View {
        let todos = store.config.todos
        let settings = store.config.tasks
        let counts = TaskLogic.counts(todos)
        let sections = TaskLogic.sections(todos, grouped: settings.groupByDue, now: now, cal: cal)
        let open = sections.filter { $0.bucket != .completed }
        let completed = sections.first { $0.bucket == .completed }

        VStack(alignment: .leading, spacing: 10) {
            header(open: counts.open, done: counts.done)
            quickAdd(atCap: todos.count >= AppConfig.maxTodos)
            if open.isEmpty && completed == nil {
                emptyState
            } else {
                list(open: open, completed: completed,
                     showHeaders: settings.groupByDue || open.count > 1,
                     showCompleted: settings.showCompleted)
            }
            if let undo { undoPill(undo) }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(dropTargeted ? 0.09 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    dropTargeted ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.clear),
                    lineWidth: 1.5
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            addDropped(urls)
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .onDisappear {
            flushPendingCompletions()
            store.tidyTodos()
        }
    }

    // MARK: Header & quick add

    private func header(open: Int, done: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tasks")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                Spacer()
                if open + done > 0 {
                    Text("\(open) left · \(done) done")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if open + done > 0 {
                GradientBar(fraction: Double(done) / Double(open + done), theme: theme, height: 3)
            }
        }
    }

    private func quickAdd(atCap: Bool) -> some View {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = trimmed.isEmpty ? nil : TaskLogic.parseQuickAdd(draft, now: now, cal: cal)
        let placeholder = atCap
            ? "The list is full — clear some done tasks"
            : dropTargeted ? "Drop to add as tasks" : "Add a task — try “tomorrow 3pm” or “!”"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.gradient)
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, design: .rounded))
                    .focused($addFocused)
                    .onSubmit(addDraft)
                    .disabled(atCap)
                if !trimmed.isEmpty {
                    Text("↩")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .help("Press Return to add")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(addFocused ? 0.075 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(addFocused ? 0.1 : 0), lineWidth: 1)
            )
            if let parsed, parsed.dueDate != nil || parsed.flagged {
                HStack(spacing: 6) {
                    if let due = parsed.dueDate {
                        chip(icon: "bell", text: DueFormat.label(due, now: now, cal: cal), tint: .accentColor)
                    }
                    if parsed.flagged {
                        chip(icon: "flag.fill", text: "Flagged", tint: .orange)
                    }
                    if !parsed.title.isEmpty, parsed.title != trimmed {
                        Text(parsed.title)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 4)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: parsed)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(theme.gradient)
            Text("Nothing on your plate")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
            Text("Type above to add a task, or drop files and links here.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    // MARK: List

    private func list(open: [TaskSection], completed: TaskSection?,
                      showHeaders: Bool, showCompleted: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if open.isEmpty {
                        allDoneLine
                    }
                    ForEach(Array(open.enumerated()), id: \.element.id) { index, section in
                        if showHeaders {
                            sectionHeader(section, first: index == 0)
                        }
                        ForEach(section.items) { todo in
                            row(todo).id(todo.id)
                        }
                    }
                    if let completed {
                        completedHeader(completed, expanded: showCompleted, first: open.isEmpty)
                        if showCompleted {
                            ForEach(completed.items) { todo in
                                row(todo).id(todo.id)
                            }
                        }
                    }
                }
                .measuringHeight($listHeight)
            }
            .frame(height: min(max(listHeight, 1), Self.maxListHeight))
            .scrollIndicators(listHeight > Self.maxListHeight ? .automatic : .never)
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id) }
                scrollTarget = nil
            }
        }
    }

    private var allDoneLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 10))
            Text("All done — nice work.")
        }
        .font(.system(.caption, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    private func sectionHeader(_ section: TaskSection, first: Bool) -> some View {
        HStack(spacing: 5) {
            Text(section.bucket.label)
                .textCase(.uppercase)
                .kerning(0.8)
            Text("\(section.items.count)")
                .monospacedDigit()
                .opacity(0.6)
            Spacer()
        }
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(section.bucket == .overdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 6)
        .padding(.top, first ? 0 : 8)
        .padding(.bottom, 2)
    }

    private func completedHeader(_ section: TaskSection, expanded: Bool, first: Bool) -> some View {
        HStack(spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { store.config.tasks.showCompleted.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Completed")
                        .textCase(.uppercase)
                        .kerning(0.8)
                    Text("\(section.items.count)")
                        .monospacedDigit()
                        .opacity(0.6)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide completed tasks" : "Show completed tasks")
            Button("Clear") {
                delete(section.items.map(\.id),
                       label: section.items.count == 1 ? "Cleared 1 task" : "Cleared \(section.items.count) tasks")
            }
            .buttonStyle(.plain)
            .font(.system(.caption2, design: .rounded).weight(.semibold))
            .foregroundStyle(.secondary)
            .help("Remove every completed task")
        }
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, first ? 0 : 10)
        .padding(.bottom, 2)
    }

    // MARK: Row

    private func row(_ todo: TodoItem) -> some View {
        let checked = todo.done || justCompleted.contains(todo.id)
        let hovering = hovered == todo.id
        let hasNotes = !(todo.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .top, spacing: 8) {
            Button {
                toggle(todo)
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(checked
                        ? AnyShapeStyle(theme.gradient)
                        : AnyShapeStyle(todo.flagged ? Color.orange : Color.secondary))
                    .contentTransition(.symbolEffect(.replace))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(checked ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if checked {
                        Text(todo.text.isEmpty ? "Untitled" : todo.text)
                            .strikethrough(true, color: .secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("Task", text: textBinding(todo.id), axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...4)
                            .onSubmit { finishEditing(todo.id) }
                    }
                    if todo.flagged && !checked {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(.subheadline, design: .rounded))

                if editingNotes == todo.id {
                    TextField("Add a note", text: notesBinding(todo.id), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1...4)
                        .focused($notesFocused)
                        .onSubmit { endNotes(todo.id) }
                        .onAppear {
                            DispatchQueue.main.async { MainActor.assumeIsolated { notesFocused = true } }
                        }
                        .onChange(of: notesFocused) { _, focused in
                            if !focused { endNotes(todo.id) }
                        }
                } else if hasNotes, let notes = todo.notes {
                    Text(notes)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .onTapGesture(count: 2) { editingNotes = todo.id }
                }

                if todo.dueDate != nil || todo.linkName != nil {
                    chips(todo, checked: checked)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Keeps a set due time visible; the hover actions cover it.
            if todo.dueDate != nil && !checked {
                clockButton(todo)
                    .opacity(hovering ? 0 : 1)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .overlay(alignment: .topTrailing) {
            if hovering {
                hoverActions(todo, checked: checked)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0))
        )
        .overlay(alignment: .top) {
            if reorderTarget == todo.id {
                Capsule()
                    .fill(theme.gradient)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
                    .offset(y: -1)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                if inside { hovered = todo.id } else if hovered == todo.id { hovered = nil }
            }
        }
        .popover(isPresented: popoverBinding(todo.id), arrowEdge: .bottom) {
            DuePopover(todoID: todo.id)
                .environmentObject(store)
        }
        .onDrag {
            NSItemProvider(object: todo.id.uuidString as NSString)
        }
        .onDrop(of: [.fileURL, .url, .plainText], isTargeted: reorderBinding(todo.id)) { providers in
            handleRowDrop(providers, before: todo.id)
        }
        .contextMenu {
            Button(todo.flagged ? "Unflag" : "Flag") { setFlag(todo.id, !todo.flagged) }
            Button(hasNotes ? "Edit note" : "Add note") { editingNotes = todo.id }
            Divider()
            Button(todo.dueDate == nil ? "Set due…" : "Change due…") { openDuePopover(todo) }
            if todo.dueDate != nil {
                Button("Remove due") { update(todo.id) { $0.dueDate = nil } }
            }
            Divider()
            Button(checked ? "Mark as not done" : "Mark as done") { toggle(todo) }
            Button("Move to top") { moveToTop(todo.id) }
                .disabled(store.config.todos.first?.id == todo.id)
            Divider()
            Button("Delete", role: .destructive) { delete([todo.id], label: deletedLabel(todo)) }
        }
        .animation(.easeInOut(duration: 0.25), value: checked)
    }

    private func hoverActions(_ todo: TodoItem, checked: Bool) -> some View {
        HStack(spacing: 9) {
            if !checked {
                Button {
                    setFlag(todo.id, !todo.flagged)
                } label: {
                    Image(systemName: todo.flagged ? "flag.fill" : "flag")
                        .foregroundStyle(todo.flagged ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help(todo.flagged ? "Unflag" : "Flag")
                clockButton(todo)
            }
            Button {
                delete([todo.id], label: deletedLabel(todo))
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .padding(.top, 3)
        .padding(.trailing, 4)
    }

    private func clockButton(_ todo: TodoItem) -> some View {
        Button {
            openDuePopover(todo)
        } label: {
            Image(systemName: todo.dueDate == nil ? "clock" : "clock.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(todo.dueDate == nil ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(theme.gradient))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help("Due time & reminder")
    }

    private func chips(_ todo: TodoItem, checked: Bool) -> some View {
        HStack(spacing: 6) {
            if let due = todo.dueDate {
                let overdue = DueFormat.isOverdue(due, now: now, done: checked)
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

    private func undoPill(_ record: TaskUndo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(record.label)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button {
                restore(record)
            } label: {
                Text("Undo")
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.gradient))
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Actions

    private func addDraft() {
        let parsed = TaskLogic.parseQuickAdd(draft, now: Date(), cal: cal)
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, store.config.todos.count < AppConfig.maxTodos else { return }
        let item = TodoItem(text: title, dueDate: parsed.dueDate, flagged: parsed.flagged)
        withAnimation(.easeOut(duration: 0.2)) {
            store.config.todos.insert(item, at: 0)
        }
        draft = ""
        addFocused = true
        scrollTarget = item.id
    }

    /// Turns each dropped file/link into a task.
    @discardableResult
    private func addDropped(_ urls: [URL]) -> Bool {
        // A dragged row's id is plain text, not a link — never a task.
        let links = urls.filter { $0.isFileURL || $0.scheme != nil }
        let free = AppConfig.maxTodos - store.config.todos.count
        guard free > 0, !links.isEmpty else { return false }
        withAnimation(.easeOut(duration: 0.2)) {
            store.config.todos.append(contentsOf: links.prefix(free).map(TodoItem.fromDroppedURL))
        }
        return true
    }

    /// A row takes three kinds of drop: another row (reorder: it moves just
    /// above this one), a file, or a link (both become new tasks).
    private func handleRowDrop(_ providers: [NSItemProvider], before target: UUID) -> Bool {
        let store = store
        let addURL: @Sendable (URL) -> Void = { url in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard url.isFileURL || url.scheme != nil,
                          store.config.todos.count < AppConfig.maxTodos else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        store.config.todos.append(TodoItem.fromDroppedURL(url))
                    }
                }
            }
        }
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { addURL(url) }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                handled = true
                _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                    guard let text = (object as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                    if let id = UUID(uuidString: text) {
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard id != target, store.config.todos.contains(where: { $0.id == id }) else { return }
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    store.config.todos = TaskLogic.moving(store.config.todos, id: id, before: target)
                                }
                            }
                        }
                    } else if let url = URL(string: text), url.scheme != nil {
                        addURL(url)
                    }
                }
            }
        }
        return handled
    }

    /// The checkmark shows at once; the task stays put, struck through, for
    /// a moment before it moves to Completed.
    private func toggle(_ todo: TodoItem) {
        let id = todo.id
        if todo.done {
            withAnimation(.easeInOut(duration: 0.25)) { update(id) { $0.done = false } }
            return
        }
        if justCompleted.contains(id) {
            PendingCompletions.ids.remove(id)
            justCompleted.remove(id)
            return
        }
        justCompleted.insert(id)
        PendingCompletions.ids.insert(id)
        let store = store
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            MainActor.assumeIsolated {
                guard PendingCompletions.ids.remove(id) != nil else { return }
                Self.complete(id, in: store)
                justCompleted.remove(id)
            }
        }
    }

    private static func complete(_ id: UUID, in store: ConfigStore) {
        guard let index = store.config.todos.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeInOut(duration: 0.3)) { store.config.todos[index].done = true }
    }

    private func flushPendingCompletions() {
        for id in justCompleted where PendingCompletions.ids.remove(id) != nil {
            Self.complete(id, in: store)
        }
        justCompleted = []
    }

    private func delete(_ ids: [UUID], label: String) {
        let removed = store.config.todos.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { (index: $0.offset, item: $0.element) }
        guard !removed.isEmpty else { return }
        for id in ids { PendingCompletions.ids.remove(id) }
        if let open = duePopover, ids.contains(open) { duePopover = nil }
        let record = TaskUndo(removed: removed, label: label)
        withAnimation(.easeInOut(duration: 0.2)) {
            store.config.todos.removeAll { ids.contains($0.id) }
            undo = record
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            MainActor.assumeIsolated {
                if undo?.id == record.id {
                    withAnimation(.easeInOut(duration: 0.2)) { undo = nil }
                }
            }
        }
    }

    /// Puts removed tasks back where they were.
    private func restore(_ record: TaskUndo) {
        var todos = store.config.todos
        for entry in record.removed.sorted(by: { $0.index < $1.index })
            where !todos.contains(where: { $0.id == entry.item.id }) {
            todos.insert(entry.item, at: min(entry.index, todos.count))
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            store.config.todos = todos
            undo = nil
        }
    }

    private func deletedLabel(_ todo: TodoItem) -> String {
        let title = todo.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Deleted a task" : "Deleted “\(title)”"
    }

    private func moveToTop(_ id: UUID) {
        guard let first = store.config.todos.first?.id, first != id else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            store.config.todos = TaskLogic.moving(store.config.todos, id: id, before: first)
        }
    }

    private func setFlag(_ id: UUID, _ flagged: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { update(id) { $0.flagged = flagged } }
    }

    /// Return in a title: a row emptied of everything goes away.
    private func finishEditing(_ id: UUID) {
        guard let todo = store.config.todos.first(where: { $0.id == id }), todo.isBlank else { return }
        withAnimation(.easeInOut(duration: 0.2)) { store.config.todos.removeAll { $0.id == id } }
    }

    private func endNotes(_ id: UUID) {
        guard editingNotes == id else { return }
        editingNotes = nil
        update(id) { todo in
            let trimmed = (todo.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { todo.notes = nil }
        }
    }

    private func openDuePopover(_ todo: TodoItem) {
        if todo.dueDate == nil {
            // Seed with the next full hour (14:30 → 15:00, 14:00 → 15:00)
            // so the picker starts somewhere sane.
            let start = Date()
            let nextHour = cal.dateInterval(of: .hour, for: start)?.end ?? start.addingTimeInterval(3600)
            update(todo.id) { $0.dueDate = nextHour }
        }
        duePopover = todo.id
    }

    // MARK: Bindings

    private func popoverBinding(_ id: UUID) -> Binding<Bool> {
        Binding {
            duePopover == id
        } set: { open in
            if !open, duePopover == id { duePopover = nil }
        }
    }

    private func reorderBinding(_ id: UUID) -> Binding<Bool> {
        Binding {
            reorderTarget == id
        } set: { targeted in
            if targeted { reorderTarget = id } else if reorderTarget == id { reorderTarget = nil }
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

    private func notesBinding(_ id: UUID) -> Binding<String> {
        Binding {
            store.config.todos.first(where: { $0.id == id })?.notes ?? ""
        } set: { notes in
            update(id) { $0.notes = notes }
        }
    }
}
