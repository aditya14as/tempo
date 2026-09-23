import Foundation
import ServiceManagement

@MainActor
final class ConfigStore: ObservableObject {
    private static let key = "tempo.config.v1"
    /// The one live store — lets AppKit-level code (menu bar drop zone)
    /// reach it without threading it through SwiftUI.
    private(set) static weak var shared: ConfigStore?

    @Published var config: AppConfig {
        didSet {
            save()
            if config.launchAtLogin != oldValue.launchAtLogin {
                applyLaunchAtLogin(config.launchAtLogin)
            }
            if config.todos != oldValue.todos || config.features.tasks != oldValue.features.tasks {
                ReminderScheduler.shared.sync(config.features.tasks ? config.todos : [])
            }
            if config.todos != oldValue.todos {
                pushDoneChangesToAppleReminders(oldTodos: oldValue.todos)
            }
            if !config.features.shelf && oldValue.features.shelf {
                ShelfWindow.shared.hide()
            }
        }
    }

    init() {
        config = Self.load()
        Self.shared = self
        // The notification's "Mark done" button checks the task off here too.
        ReminderScheduler.shared.activate { [weak self] todoID in
            guard let self, let index = self.config.todos.firstIndex(where: { $0.id == todoID }) else { return }
            self.config.todos[index].done = true
        }
        // Re-arm due-task notifications after a relaunch or reboot.
        ReminderScheduler.shared.sync(config.features.tasks ? config.todos : [])
    }

    /// Checking a task off in Tempo completes its Apple reminder (and back).
    private func pushDoneChangesToAppleReminders(oldTodos: [TodoItem]) {
        let oldDone = Dictionary(uniqueKeysWithValues: oldTodos.map { ($0.id, $0.done) })
        for todo in config.todos {
            guard let reminderID = todo.reminderID, oldDone[todo.id] != todo.done else { continue }
            AppleReminders.setCompleted(reminderID, done: todo.done)
        }
    }

    /// Files/links landing on the Shelf (from the shelf window or the
    /// menu bar icon). Never a silent no-op: repeats move to the front,
    /// a full shelf drops its oldest item.
    @discardableResult
    func addToShelf(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        config.shelf = ShelfItem.merged(shelf: config.shelf, dropped: urls)
        return true
    }

    /// Drops "+" rows that were never filled in.
    func pruneBlankTodos() {
        if config.todos.contains(where: \.isBlank) {
            config.todos.removeAll(where: \.isBlank)
        }
    }

    /// Pulls completed-state from Apple Reminders (called when the panel opens):
    /// a task finished in the Reminders app gets checked off here, and one
    /// re-opened there re-opens here.
    func pullAppleReminderCompletions() {
        let ids = config.todos.compactMap(\.reminderID)
        guard !ids.isEmpty else { return }
        AppleReminders.completions(for: ids) { [weak self] map in
            guard let self, !map.isEmpty else { return }
            let merged = DueFormat.applyingCompletions(self.config.todos, map)
            if merged != self.config.todos {
                self.config.todos = merged
            }
        }
    }

    private static func load() -> AppConfig {
        guard let data = UserDefaults.standard.data(forKey: key) else { return AppConfig() }
        if let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return decoded
        }
        if let legacy = try? JSONDecoder().decode(LegacyConfig.self, from: data) {
            return legacy.migrated()
        }
        return AppConfig()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Only effective when running from a proper .app bundle; fails silently otherwise.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Running as a bare binary (swift run) — ignore.
        }
    }
}

// MARK: - v1 config migration (single shared work window + month/year mode enums)

private struct LegacyConfig: Codable {
    struct Schedule: Codable {
        var startMinute: Int
        var endMinute: Int
        var workdays: Set<Int>
    }

    var schedule: Schedule
    var rowToday: RowConfig
    var rowWeek: RowConfig
    var rowMonth: RowConfig
    var rowYear: RowConfig
    var monthMode: ProgressMode
    var yearMode: ProgressMode
    var menuBarStyle: MenuBarStyle
    var menuBarMetric: Metric
    var theme: Theme
    var launchAtLogin: Bool

    func migrated() -> AppConfig {
        var config = AppConfig()
        var work = WorkSchedule()
        for weekday in 1...7 {
            work.setDay(weekday, DaySchedule(
                enabled: schedule.workdays.contains(weekday),
                startMinute: schedule.startMinute,
                endMinute: schedule.endMinute
            ))
        }
        config.schedule = work
        config.rowToday = rowToday
        config.rowWeek = rowWeek
        config.rowMonth = rowMonth
        config.rowYear = rowYear
        config.weekBasis = .daily
        config.monthBasis = monthMode == .calendar ? .calendar : .daily
        config.yearBasis = yearMode == .calendar ? .calendar : .daily
        config.menuBarStyle = menuBarStyle
        config.menuBarShows = MenuBarShows(rawValue: menuBarMetric.rawValue) ?? .todayWeek
        config.theme = theme
        config.launchAtLogin = launchAtLogin
        return config
    }
}

final class Ticker: ObservableObject {
    @Published var now = Date()
    private var timer: Timer?

    init(interval: TimeInterval = 30) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit { timer?.invalidate() }
}
