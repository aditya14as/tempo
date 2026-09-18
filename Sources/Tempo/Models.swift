import Foundation
import SwiftUI

enum ProgressMode: String, Codable, CaseIterable, Identifiable {
    case workHours
    case calendar

    var id: String { rawValue }
    var label: String {
        switch self {
        case .workHours: return "Work hours"
        case .calendar: return "Calendar"
        }
    }
}

struct WorkSlot: Codable, Equatable, Identifiable {
    var id = UUID()
    var startMinute: Int
    var endMinute: Int

    var seconds: Double { Double(max(0, endMinute - startMinute)) * 60 }
}

struct DaySchedule: Codable, Equatable {
    var enabled: Bool
    /// One or more work windows within the day, e.g. 11:00–12:00 and 14:00–15:00.
    var slots: [WorkSlot]

    init(enabled: Bool, slots: [WorkSlot]) {
        self.enabled = enabled
        self.slots = slots.isEmpty ? [WorkSlot(startMinute: 10 * 60, endMinute: 18 * 60)] : slots
    }

    init(enabled: Bool, startMinute: Int, endMinute: Int) {
        self.init(enabled: enabled, slots: [WorkSlot(startMinute: startMinute, endMinute: endMinute)])
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, slots, startMinute, endMinute
    }

    /// Decodes both shapes: the new slot list, and the old single start/end window.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? true
        if let decoded = ((try? c.decodeIfPresent([WorkSlot].self, forKey: .slots)) ?? nil), !decoded.isEmpty {
            self.init(enabled: enabled, slots: decoded)
        } else {
            let start = ((try? c.decodeIfPresent(Int.self, forKey: .startMinute)) ?? nil) ?? 10 * 60
            let end = ((try? c.decodeIfPresent(Int.self, forKey: .endMinute)) ?? nil) ?? 18 * 60
            self.init(enabled: enabled, startMinute: start, endMinute: end)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(slots, forKey: .slots)
    }

    var seconds: Double { enabled ? slots.reduce(0) { $0 + $1.seconds } : 0 }
    /// Earliest slot start — when the workday begins.
    var startMinute: Int { slots.map(\.startMinute).min() ?? 10 * 60 }
    /// Latest slot end — when the workday is over.
    var endMinute: Int { slots.map(\.endMinute).max() ?? 18 * 60 }
}

struct WorkSchedule: Codable, Equatable {
    /// Keyed by Calendar weekday, 1 = Sunday … 7 = Saturday.
    var days: [Int: DaySchedule]

    init() {
        var d: [Int: DaySchedule] = [:]
        for weekday in 1...7 {
            d[weekday] = DaySchedule(
                enabled: (2...6).contains(weekday),  // Mon–Fri
                startMinute: 10 * 60,
                endMinute: 18 * 60
            )
        }
        days = d
    }

    func day(_ weekday: Int) -> DaySchedule {
        days[weekday] ?? DaySchedule(enabled: false, startMinute: 10 * 60, endMinute: 18 * 60)
    }

    mutating func setDay(_ weekday: Int, _ schedule: DaySchedule) {
        days[weekday] = schedule
    }

    var enabledCount: Int { days.values.filter(\.enabled).count }
    var weekSeconds: Double { days.values.reduce(0) { $0 + $1.seconds } }
    var weekHours: Int { max(1, Int((weekSeconds / 3600).rounded())) }
}

enum Metric: String, Codable, CaseIterable, Identifiable {
    case today, week, month, year

    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }
    var shortLetter: String {
        switch self {
        case .today: return "T"
        case .week: return "W"
        case .month: return "M"
        case .year: return "Y"
        }
    }
}

/// What the menu bar item tracks: one metric, or today + week together.
enum MenuBarShows: String, Codable, CaseIterable, Identifiable {
    case today, week, month, year, todayWeek

    var id: String { rawValue }
    var label: String {
        switch self {
        case .todayWeek: return "Both"
        default: return metric?.title ?? rawValue
        }
    }
    /// The single metric, or nil for the combined today + week mode.
    var metric: Metric? { Metric(rawValue: rawValue) }
}

// MARK: - Counting basis (what each period's progress is measured against)
// Each period either defines its own rule or inherits the one below it:
// year → month → week → daily work hours.

enum WeekBasis: String, Codable, CaseIterable, Identifiable {
    case daily, calendar

    var id: String { rawValue }
    var label: String {
        switch self {
        case .daily: return "Work hours"
        case .calendar: return "Calendar"
        }
    }
}

enum MonthBasis: String, Codable, CaseIterable, Identifiable {
    case weekly, daily, calendar

    var id: String { rawValue }
    var label: String {
        switch self {
        case .weekly: return "Like week"
        case .daily: return "Work hours"
        case .calendar: return "Calendar"
        }
    }
}

enum YearBasis: String, Codable, CaseIterable, Identifiable {
    case monthly, weekly, daily, calendar

    var id: String { rawValue }
    var label: String {
        switch self {
        case .monthly: return "Like month"
        case .weekly: return "Like week"
        case .daily: return "Work hours"
        case .calendar: return "Calendar"
        }
    }
}

enum RowStyle: String, Codable, CaseIterable, Identifiable {
    case percent, bar, ring, dots

    var id: String { rawValue }
    var label: String {
        switch self {
        case .percent: return "%"
        case .bar: return "Bar"
        case .ring: return "Ring"
        case .dots: return "Dots"
        }
    }
}

enum MenuBarStyle: String, Codable, CaseIterable, Identifiable {
    case text, icon, ring

    var id: String { rawValue }
    var label: String {
        switch self {
        case .text: return "Live %"
        case .icon: return "Icon"
        case .ring: return "Ring"
        }
    }
}

enum Theme: String, Codable, CaseIterable, Identifiable {
    case aurora, sunset, ocean, mono

    var id: String { rawValue }
    var label: String {
        switch self {
        case .aurora: return "Aurora"
        case .sunset: return "Sunset"
        case .ocean: return "Ocean"
        case .mono: return "Mono"
        }
    }

    var colors: [Color] {
        switch self {
        case .aurora:
            return [Color(red: 0.35, green: 0.92, blue: 0.76), Color(red: 0.45, green: 0.45, blue: 0.98)]
        case .sunset:
            return [Color(red: 1.00, green: 0.62, blue: 0.26), Color(red: 0.98, green: 0.30, blue: 0.55)]
        case .ocean:
            return [Color(red: 0.25, green: 0.85, blue: 0.98), Color(red: 0.20, green: 0.42, blue: 0.96)]
        case .mono:
            return [Color(white: 0.85), Color(white: 0.45)]
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

struct RowConfig: Codable, Equatable {
    var visible: Bool = true
    var style: RowStyle = .bar
}

struct TodoItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var done: Bool = false
    /// When set, Tempo fires a notification at this moment (and shows a due chip).
    var dueDate: Date? = nil
    /// A dropped file's path or a dropped URL; the chip opens it on click.
    var link: String? = nil
    /// Apple Reminders identifier once exported — lets done-state sync both ways.
    var reminderID: String? = nil

    /// An abandoned "+" row: nothing typed, nothing attached, no due time.
    var isBlank: Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty && link == nil && dueDate == nil
    }

    /// The attached file/URL as something openable, or nil.
    var linkURL: URL? {
        guard let link, !link.isEmpty else { return nil }
        if link.hasPrefix("/") { return URL(fileURLWithPath: link) }
        return URL(string: link)
    }

    /// Short display name for the attachment chip.
    var linkName: String? {
        guard let link, !link.isEmpty else { return nil }
        if link.hasPrefix("/") { return (link as NSString).lastPathComponent }
        return URL(string: link)?.host ?? link
    }

    /// Builds a task from a file or web URL dropped onto the list.
    static func fromDroppedURL(_ url: URL) -> TodoItem {
        if url.isFileURL {
            return TodoItem(text: url.lastPathComponent, link: url.path)
        }
        return TodoItem(text: url.absoluteString, link: url.absoluteString)
    }
}

/// A file or link parked on the floating Shelf, ready to drag somewhere else.
struct ShelfItem: Codable, Equatable, Identifiable {
    var id = UUID()
    /// File path (starts with "/") or a web URL string.
    var link: String
    var addedAt: Date = Date()

    var url: URL? {
        if link.hasPrefix("/") { return URL(fileURLWithPath: link) }
        return URL(string: link)
    }

    var name: String {
        if link.hasPrefix("/") { return (link as NSString).lastPathComponent }
        return URL(string: link)?.host ?? link
    }

    var isFile: Bool { link.hasPrefix("/") }

    static func fromDroppedURL(_ url: URL) -> ShelfItem {
        ShelfItem(link: url.isFileURL ? url.path : url.absoluteString)
    }

    /// New drops land at the FRONT of the shelf. Dropping something already
    /// there moves it to the front (instead of being silently ignored), and
    /// when the shelf is full the oldest item falls off the end — so a drop
    /// always visibly does something.
    static func merged(shelf: [ShelfItem], dropped: [URL], cap: Int = AppConfig.maxShelf) -> [ShelfItem] {
        var result = shelf
        for url in dropped.reversed() {
            let item = ShelfItem.fromDroppedURL(url)
            if let index = result.firstIndex(where: { $0.link == item.link }) {
                let existing = result.remove(at: index)
                result.insert(existing, at: 0)
            } else {
                result.insert(item, at: 0)
            }
        }
        if result.count > cap {
            result.removeLast(result.count - cap)
        }
        return result
    }
}

struct AppConfig: Codable, Equatable {
    var schedule = WorkSchedule()
    var rowToday = RowConfig(visible: true, style: .ring)
    var rowWeek = RowConfig(visible: true, style: .bar)
    var rowMonth = RowConfig(visible: true, style: .bar)
    var rowYear = RowConfig(visible: true, style: .dots)
    var weekBasis: WeekBasis = .daily
    var monthBasis: MonthBasis = .weekly
    var yearBasis: YearBasis = .monthly
    var menuBarStyle: MenuBarStyle = .text
    var menuBarShows: MenuBarShows = .todayWeek
    var theme: Theme = .aurora
    var launchAtLogin: Bool = false
    /// Up to 5 focus tasks shown in the panel.
    var todos: [TodoItem] = []
    /// Files/links parked on the floating Shelf.
    var shelf: [ShelfItem] = []

    static let maxTodos = 5
    static let maxShelf = 12

    init() {}

    /// Tolerant decoding: missing keys fall back to defaults so adding a new
    /// setting never wipes a user's saved config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        schedule = (try? c.decodeIfPresent(WorkSchedule.self, forKey: .schedule)) ?? d.schedule
        rowToday = (try? c.decodeIfPresent(RowConfig.self, forKey: .rowToday)) ?? d.rowToday
        rowWeek = (try? c.decodeIfPresent(RowConfig.self, forKey: .rowWeek)) ?? d.rowWeek
        rowMonth = (try? c.decodeIfPresent(RowConfig.self, forKey: .rowMonth)) ?? d.rowMonth
        rowYear = (try? c.decodeIfPresent(RowConfig.self, forKey: .rowYear)) ?? d.rowYear
        weekBasis = (try? c.decodeIfPresent(WeekBasis.self, forKey: .weekBasis)) ?? d.weekBasis
        monthBasis = (try? c.decodeIfPresent(MonthBasis.self, forKey: .monthBasis)) ?? d.monthBasis
        yearBasis = (try? c.decodeIfPresent(YearBasis.self, forKey: .yearBasis)) ?? d.yearBasis
        menuBarStyle = (try? c.decodeIfPresent(MenuBarStyle.self, forKey: .menuBarStyle)) ?? d.menuBarStyle
        menuBarShows = (try? c.decodeIfPresent(MenuBarShows.self, forKey: .menuBarShows)) ?? d.menuBarShows
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? d.theme
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? d.launchAtLogin
        todos = (try? c.decodeIfPresent([TodoItem].self, forKey: .todos)) ?? d.todos
        shelf = (try? c.decodeIfPresent([ShelfItem].self, forKey: .shelf)) ?? d.shelf
    }

    func row(_ metric: Metric) -> RowConfig {
        switch metric {
        case .today: return rowToday
        case .week: return rowWeek
        case .month: return rowMonth
        case .year: return rowYear
        }
    }

    mutating func setRow(_ metric: Metric, _ row: RowConfig) {
        switch metric {
        case .today: rowToday = row
        case .week: rowWeek = row
        case .month: rowMonth = row
        case .year: rowYear = row
        }
    }

    /// Walks the inheritance chain down to a concrete counting rule.
    func resolvedMode(for metric: Metric) -> ProgressMode {
        switch metric {
        case .today:
            return .workHours
        case .week:
            return weekBasis == .calendar ? .calendar : .workHours
        case .month:
            switch monthBasis {
            case .calendar: return .calendar
            case .daily: return .workHours
            case .weekly: return resolvedMode(for: .week)
            }
        case .year:
            switch yearBasis {
            case .calendar: return .calendar
            case .daily: return .workHours
            case .weekly: return resolvedMode(for: .week)
            case .monthly: return resolvedMode(for: .month)
            }
        }
    }
}
