import Foundation

struct MetricSnapshot {
    /// 0…1, or nil when the metric doesn't apply right now (e.g. Today on a day off).
    var fraction: Double?
    var subtitle: String
}

enum ProgressEngine {
    /// Gregorian calendar with weeks starting on Monday, in the user's time zone.
    static var mondayCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        return cal
    }

    // MARK: - Building blocks

    static func secondsIntoDay(_ date: Date, cal: Calendar) -> Double {
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        return Double((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0))
    }

    /// Work seconds elapsed within `now`'s own day, clamped to the work window.
    static func elapsedWorkSeconds(now: Date, schedule: WorkSchedule, cal: Calendar) -> Double {
        let start = Double(schedule.startMinute) * 60
        let end = Double(schedule.endMinute) * 60
        guard end > start else { return 0 }
        return min(max(secondsIntoDay(now, cal: cal) - start, 0), end - start)
    }

    static func isWorkday(_ date: Date, schedule: WorkSchedule, cal: Calendar) -> Bool {
        schedule.workdays.contains(cal.component(.weekday, from: date))
    }

    /// Work seconds (done, total) across all workdays in [from, to).
    static func workTally(
        now: Date, from: Date, to: Date, schedule: WorkSchedule, cal: Calendar
    ) -> (done: Double, total: Double) {
        var done = 0.0
        var total = 0.0
        let perDay = schedule.secondsPerDay
        let today = cal.startOfDay(for: now)
        var day = cal.startOfDay(for: from)
        let endDay = cal.startOfDay(for: to)
        while day < endDay {
            if isWorkday(day, schedule: schedule, cal: cal) {
                total += perDay
                if day < today {
                    done += perDay
                } else if day == today {
                    done += elapsedWorkSeconds(now: now, schedule: schedule, cal: cal)
                }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return (done, total)
    }

    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    // MARK: - Metric fractions

    static func dayProgress(now: Date, schedule: WorkSchedule, cal: Calendar) -> Double? {
        guard isWorkday(now, schedule: schedule, cal: cal), schedule.secondsPerDay > 0 else { return nil }
        return elapsedWorkSeconds(now: now, schedule: schedule, cal: cal) / schedule.secondsPerDay
    }

    static func periodInterval(_ metric: Metric, now: Date, cal: Calendar) -> DateInterval? {
        switch metric {
        case .today: return cal.dateInterval(of: .day, for: now)
        case .week: return cal.dateInterval(of: .weekOfYear, for: now)
        case .month: return cal.dateInterval(of: .month, for: now)
        case .year: return cal.dateInterval(of: .year, for: now)
        }
    }

    static func rangeProgress(
        metric: Metric, mode: ProgressMode, now: Date, schedule: WorkSchedule, cal: Calendar
    ) -> Double {
        guard let interval = periodInterval(metric, now: now, cal: cal) else { return 0 }
        switch mode {
        case .calendar:
            guard interval.duration > 0 else { return 0 }
            return clamp01(now.timeIntervalSince(interval.start) / interval.duration)
        case .workHours:
            let tally = workTally(now: now, from: interval.start, to: interval.end, schedule: schedule, cal: cal)
            guard tally.total > 0 else { return 0 }
            return clamp01(tally.done / tally.total)
        }
    }

    // MARK: - Snapshots (fraction + human subtitle)

    static func snapshot(
        _ metric: Metric, now: Date, config: AppConfig, cal: Calendar = ProgressEngine.mondayCalendar
    ) -> MetricSnapshot {
        let schedule = config.schedule
        switch metric {
        case .today:
            guard let frac = dayProgress(now: now, schedule: schedule, cal: cal) else {
                return MetricSnapshot(fraction: nil, subtitle: "Day off")
            }
            let startSec = Double(schedule.startMinute) * 60
            let nowSec = secondsIntoDay(now, cal: cal)
            if nowSec < startSec {
                return MetricSnapshot(fraction: 0, subtitle: "Starts in \(hm(startSec - nowSec))")
            }
            if frac >= 1 {
                return MetricSnapshot(fraction: 1, subtitle: "Done for today")
            }
            let left = schedule.secondsPerDay * (1 - frac)
            return MetricSnapshot(fraction: frac, subtitle: "\(hm(left)) left")

        case .week:
            let frac = rangeProgress(metric: .week, mode: .workHours, now: now, schedule: schedule, cal: cal)
            if frac >= 1 {
                return MetricSnapshot(fraction: 1, subtitle: "Week done — enjoy!")
            }
            guard let interval = periodInterval(.week, now: now, cal: cal) else {
                return MetricSnapshot(fraction: frac, subtitle: "")
            }
            let tally = workTally(now: now, from: interval.start, to: interval.end, schedule: schedule, cal: cal)
            return MetricSnapshot(fraction: frac, subtitle: "\(hm(tally.total - tally.done)) of work left")

        case .month, .year:
            let mode = config.mode(for: metric)
            let frac = rangeProgress(metric: metric, mode: mode, now: now, schedule: schedule, cal: cal)
            guard let interval = periodInterval(metric, now: now, cal: cal) else {
                return MetricSnapshot(fraction: frac, subtitle: "")
            }
            switch mode {
            case .workHours:
                let tally = workTally(now: now, from: interval.start, to: interval.end, schedule: schedule, cal: cal)
                let daysLeft = schedule.secondsPerDay > 0
                    ? Int(((tally.total - tally.done) / schedule.secondsPerDay).rounded(.up))
                    : 0
                return MetricSnapshot(fraction: frac, subtitle: "\(daysLeft) workdays left")
            case .calendar:
                let daysLeft = max(0, cal.dateComponents([.day], from: now, to: interval.end).day ?? 0)
                return MetricSnapshot(fraction: frac, subtitle: "\(daysLeft) days left")
            }
        }
    }

    // MARK: - Formatting

    static func hm(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes >= 60 {
            let m = minutes % 60
            return m == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(m)m"
        }
        return "\(max(minutes, 0))m"
    }

    static func percentText(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((clamp01(fraction) * 100).rounded()))%"
    }
}
