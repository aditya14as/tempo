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

struct DaySchedule: Codable, Equatable {
    var enabled: Bool
    var startMinute: Int
    var endMinute: Int

    var seconds: Double { enabled ? Double(max(0, endMinute - startMinute)) * 60 : 0 }
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
