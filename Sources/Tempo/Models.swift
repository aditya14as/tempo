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

struct WorkSchedule: Codable, Equatable {
    var startMinute: Int = 10 * 60
    var endMinute: Int = 18 * 60
    /// Calendar weekday numbers, 1 = Sunday … 7 = Saturday.
    var workdays: Set<Int> = [2, 3, 4, 5, 6]

    var secondsPerDay: Double { Double(max(0, endMinute - startMinute)) * 60 }
    var hoursPerDay: Int { max(1, Int((Double(max(0, endMinute - startMinute)) / 60).rounded())) }
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
    var monthMode: ProgressMode = .workHours
    var yearMode: ProgressMode = .workHours
    var menuBarStyle: MenuBarStyle = .text
    var menuBarMetric: Metric = .week
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

    func mode(for metric: Metric) -> ProgressMode {
        switch metric {
        case .today, .week: return .workHours
        case .month: return monthMode
        case .year: return yearMode
        }
    }
}
