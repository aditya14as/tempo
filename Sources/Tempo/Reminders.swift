import AppKit
import EventKit
import Foundation
import UserNotifications

// MARK: - Due-date display (pure, covered by --check)

enum DueFormat {
    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// "Today 15:00", "Tomorrow 09:30", or "Wed 23 Sep 15:00".
    static func label(_ due: Date, now: Date, cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.hour, .minute], from: due)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        if cal.isDate(due, inSameDayAs: now) { return "Today \(time)" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
            cal.isDate(due, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        let d = cal.dateComponents([.weekday, .day, .month], from: due)
        let weekday = weekdays[((d.weekday ?? 1) - 1 + 7) % 7]
        let month = months[max(0, min(11, (d.month ?? 1) - 1))]
        return "\(weekday) \(d.day ?? 1) \(month) \(time)"
    }

    static func isOverdue(_ due: Date, now: Date, done: Bool) -> Bool {
        !done && due < now
    }

    /// Tasks whose notification should be pending: not done, has text, due in the future.
    static func pendingReminders(_ todos: [TodoItem], now: Date) -> [TodoItem] {
        todos.filter { todo in
            guard !todo.done, let due = todo.dueDate, due > now else { return false }
            return !todo.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// The components Apple Reminders and notification triggers key on.
    static func triggerComponents(_ due: Date, cal: Calendar = .current) -> DateComponents {
        cal.dateComponents([.year, .month, .day, .hour, .minute], from: due)
    }

    /// Tasks due on one specific day, soonest first.
    static func tasks(_ todos: [TodoItem], dueOn day: Date, cal: Calendar) -> [TodoItem] {
        todos
            .filter { $0.dueDate.map { cal.isDate($0, inSameDayAs: day) } ?? false }
            .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
    }

    /// All dated tasks, soonest first — feeds the Week tab's agenda list.
    static func agenda(_ todos: [TodoItem]) -> [TodoItem] {
        todos.filter { $0.dueDate != nil }
            .sorted { ($0.dueDate ?? .distantPast) < ($1.dueDate ?? .distantPast) }
    }

    /// Applies Apple Reminders' completed-state onto matching tasks (both ways:
    /// a completed reminder marks the task done, an un-completed one re-opens it).
    static func applyingCompletions(_ todos: [TodoItem], _ completed: [String: Bool]) -> [TodoItem] {
        todos.map { todo in
            guard let id = todo.reminderID, let isDone = completed[id], todo.done != isDone else {
                return todo
            }
            var todo = todo
            todo.done = isDone
            return todo
        }
    }
}

// MARK: - One-tap due choices (pure, covered by --check)

enum QuickDue {
    /// Two hours out, snapped up to the next quarter hour.
    static func inTwoHours(_ now: Date, cal: Calendar) -> Date {
        let raw = now.addingTimeInterval(2 * 3600)
        let minute = cal.component(.minute, from: raw)
        let snap = (15 - minute % 15) % 15
        let snapped = raw.addingTimeInterval(Double(snap) * 60)
        // Drop stray seconds so the label reads clean.
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: snapped)
        return cal.date(from: c) ?? snapped
    }

    /// Today at 18:00.
    static func tonight(_ now: Date, cal: Calendar) -> Date {
        cal.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
    }

    /// Tomorrow when that day's work starts (10:00 when the day is off).
    static func tomorrowMorning(_ now: Date, schedule: WorkSchedule, cal: Calendar) -> Date {
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
        let day = schedule.day(cal.component(.weekday, from: tomorrow))
        let minute = day.enabled ? day.startMinute : 10 * 60
        return cal.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: tomorrow) ?? tomorrow
    }

    /// Next week's Monday at that day's work start.
    static func nextMonday(_ now: Date, schedule: WorkSchedule, cal: Calendar) -> Date {
        var day = cal.startOfDay(for: now)
        repeat {
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day
        } while cal.component(.weekday, from: day) != 2
        let sched = schedule.day(2)
        let minute = sched.enabled ? sched.startMinute : 10 * 60
        return cal.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
    }
}

// MARK: - Local notifications when a task comes due

@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()
    nonisolated static let idPrefix = "tempo.todo."
    nonisolated static let doneActionID = "TEMPO_MARK_DONE"
    nonisolated static let categoryID = "TEMPO_TODO"

    private let delegate = NotificationDelegate()

    /// UNUserNotificationCenter only works from a real .app bundle;
    /// `swift run` and `--check` must never touch it.
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    /// The task UUID hiding inside one of our notification identifiers.
    nonisolated static func todoID(fromNotificationID id: String) -> UUID? {
        guard id.hasPrefix(idPrefix) else { return nil }
        return UUID(uuidString: String(id.dropFirst(idPrefix.count)))
    }

    /// Hooks up the "Mark done" notification button. Call once at launch.
    func activate(onMarkDone: @escaping @MainActor (UUID) -> Void) {
        guard available else { return }
        delegate.onMarkDone = onMarkDone
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let done = UNNotificationAction(identifier: Self.doneActionID, title: "Mark done")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [done], intentIdentifiers: [])
        ])
    }

    /// Makes pending notifications mirror the task list: one per future due
    /// task. Also clears already-shown notifications for tasks now done/gone.
    func sync(_ todos: [TodoItem], now: Date = Date()) {
        guard available else { return }
        let pending = DueFormat.pendingReminders(todos, now: now)
        let activeIDs = Set(todos.filter { !$0.done }.map { Self.idPrefix + $0.id.uuidString })
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            center.getPendingNotificationRequests { requests in
                let ours = requests.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
                center.removePendingNotificationRequests(withIdentifiers: ours)
                guard granted else { return }
                for todo in pending {
                    guard let due = todo.dueDate else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = "Tempo"
                    content.body = todo.text
                    content.sound = .default
                    content.categoryIdentifier = Self.categoryID
                    let trigger = UNCalendarNotificationTrigger(
                        dateMatching: DueFormat.triggerComponents(due), repeats: false
                    )
                    center.add(UNNotificationRequest(
                        identifier: Self.idPrefix + todo.id.uuidString,
                        content: content, trigger: trigger
                    ))
                }
            }
            center.getDeliveredNotifications { delivered in
                let stale = delivered.map(\.request.identifier)
                    .filter { $0.hasPrefix(Self.idPrefix) && !activeIDs.contains($0) }
                if !stale.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: stale)
                }
            }
        }
    }
}

/// Routes the notification's "Mark done" button back into the app.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var onMarkDone: (@MainActor (UUID) -> Void)?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == ReminderScheduler.doneActionID,
            let todoID = ReminderScheduler.todoID(fromNotificationID: response.notification.request.identifier) {
            DispatchQueue.main.async { [onMarkDone] in
                MainActor.assumeIsolated { onMarkDone?(todoID) }
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even while Tempo is frontmost.
        completionHandler([.banner, .sound])
    }
}

// MARK: - Export a task into the Apple Reminders app

enum AppleReminders {
    /// One store for the app: identifiers stay valid across calls.
    private static let store = EKEventStore()

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// Adds the task to the default Reminders list; hands back a status line
    /// and the new reminder's identifier so done-state can sync later.
    static func add(_ todo: TodoItem, completion: @escaping @MainActor (String, String?) -> Void) {
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async {
                guard granted else {
                    completion("No access — allow Reminders in System Settings → Privacy", nil)
                    return
                }
                let reminder = EKReminder(eventStore: store)
                let text = todo.text.trimmingCharacters(in: .whitespaces)
                reminder.title = text.isEmpty ? "Task from Tempo" : text
                reminder.calendar = store.defaultCalendarForNewReminders()
                reminder.isCompleted = todo.done
                if let due = todo.dueDate {
                    reminder.dueDateComponents = DueFormat.triggerComponents(due)
                    reminder.addAlarm(EKAlarm(absoluteDate: due))
                }
                if let link = todo.link { reminder.notes = link }
                do {
                    try store.save(reminder, commit: true)
                    completion("Added to Reminders ✓", reminder.calendarItemIdentifier)
                } catch {
                    completion("Couldn't save: \(error.localizedDescription)", nil)
                }
            }
        }
    }

    /// Pushes a task's done state onto its Apple reminder (quietly, no prompt).
    static func setCompleted(_ reminderID: String, done: Bool) {
        guard hasAccess,
            let reminder = store.calendarItem(withIdentifier: reminderID) as? EKReminder,
            reminder.isCompleted != done
        else { return }
        reminder.isCompleted = done
        try? store.save(reminder, commit: true)
    }

    /// Reads back completed-state for exported tasks: [reminderID: isCompleted].
    /// Deleted reminders simply don't appear in the result.
    static func completions(for ids: [String], completion: @escaping @MainActor ([String: Bool]) -> Void) {
        guard hasAccess, !ids.isEmpty else {
            DispatchQueue.main.async { completion([:]) }
            return
        }
        DispatchQueue.main.async {
            var map: [String: Bool] = [:]
            for id in ids {
                if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder {
                    map[id] = reminder.isCompleted
                }
            }
            completion(map)
        }
    }
}
