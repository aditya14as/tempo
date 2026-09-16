import Foundation
import ServiceManagement

@MainActor
final class ConfigStore: ObservableObject {
    private static let key = "tempo.config.v1"

    @Published var config: AppConfig {
        didSet {
            save()
            if config.launchAtLogin != oldValue.launchAtLogin {
                applyLaunchAtLogin(config.launchAtLogin)
            }
            if config.todos != oldValue.todos {
                ReminderScheduler.shared.sync(config.todos)
            }
        }
    }

    init() {
        config = Self.load()
        // Re-arm due-task notifications after a relaunch or reboot.
        ReminderScheduler.shared.sync(config.todos)
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
