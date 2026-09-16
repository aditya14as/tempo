import Foundation

/// Self-checks for the progress math, run with `Tempo --check`.
/// Command Line Tools ship no XCTest/Testing module, so tests live here as
/// plain assertions executed before the app would launch.
enum Checks {
    private static var failures = 0

    private static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("  ok  \(label)")
        } else {
            failures += 1
            print("FAIL  \(label)")
        }
    }

    private static func expectClose(_ a: Double, _ b: Double, _ label: String, accuracy: Double = 0.0001) {
        expect(abs(a - b) <= accuracy, "\(label) (got \(a), want \(b))")
    }

    static func runAll() -> Int {
        let cal = ProgressEngine.mondayCalendar
        let schedule = WorkSchedule()  // Mon–Fri, 10:00–18:00

        // A day in an arbitrary fixed week, at a given time. dayOffset 0 = Monday.
        func weekDate(dayOffset: Int, hour: Int, minute: Int = 0) -> Date {
            let monday = cal.date(from: DateComponents(weekday: 2, weekOfYear: 20, yearForWeekOfYear: 2026))!
            let day = cal.date(byAdding: .day, value: dayOffset, to: monday)!
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }

        let wednesday14 = weekDate(dayOffset: 2, hour: 14)

        expectClose(
            ProgressEngine.dayProgress(now: wednesday14, schedule: schedule, cal: cal) ?? -1, 0.5,
            "day midpoint is 50%"
        )
        expectClose(
            ProgressEngine.dayProgress(now: weekDate(dayOffset: 0, hour: 8), schedule: schedule, cal: cal) ?? -1, 0,
            "before 10:00 clamps to 0%"
        )
        expectClose(
            ProgressEngine.dayProgress(now: weekDate(dayOffset: 0, hour: 20), schedule: schedule, cal: cal) ?? -1, 1,
            "after 18:00 clamps to 100%"
        )
        expect(
            ProgressEngine.dayProgress(now: weekDate(dayOffset: 5, hour: 12), schedule: schedule, cal: cal) == nil,
            "Saturday has no day progress"
        )

        let week = ProgressEngine.periodInterval(.week, now: wednesday14, cal: cal)!
        let tally = ProgressEngine.workTally(now: wednesday14, from: week.start, to: week.end, schedule: schedule, cal: cal)
        expectClose(tally.total, 40 * 3600, "week totals 40 work hours", accuracy: 0.5)
        expectClose(tally.done, 20 * 3600, "Wed 14:00 has 20h done", accuracy: 0.5)
        expectClose(
            ProgressEngine.rangeProgress(metric: .week, mode: .workHours, now: wednesday14, schedule: schedule, cal: cal),
            0.5, "week midpoint is 50%"
        )
        expectClose(
            ProgressEngine.rangeProgress(metric: .week, mode: .workHours, now: weekDate(dayOffset: 6, hour: 12), schedule: schedule, cal: cal),
            1, "Sunday week is 100%"
        )
        expectClose(
            ProgressEngine.rangeProgress(metric: .week, mode: .workHours, now: weekDate(dayOffset: 0, hour: 9, minute: 59), schedule: schedule, cal: cal),
            0, "Monday 09:59 week is 0%"
        )

        let month = ProgressEngine.periodInterval(.month, now: wednesday14, cal: cal)!
        expectClose(
            ProgressEngine.rangeProgress(metric: .month, mode: .calendar, now: wednesday14, schedule: schedule, cal: cal),
            wednesday14.timeIntervalSince(month.start) / month.duration,
            "calendar-mode month matches plain elapsed time"
        )

        // Per-day hours: short Friday (10:00–17:00) shrinks the week to 39h.
        var shortFriday = schedule
        shortFriday.setDay(6, DaySchedule(enabled: true, startMinute: 10 * 60, endMinute: 17 * 60))
        let shortTally = ProgressEngine.workTally(now: wednesday14, from: week.start, to: week.end, schedule: shortFriday, cal: cal)
        expectClose(shortTally.total, 39 * 3600, "short Friday shrinks week to 39h", accuracy: 0.5)
        expectClose(
            ProgressEngine.rangeProgress(metric: .week, mode: .workHours, now: wednesday14, schedule: shortFriday, cal: cal),
            20.0 / 39.0, "week fraction honors per-day hours"
        )
        expectClose(
            ProgressEngine.dayProgress(now: weekDate(dayOffset: 4, hour: 13, minute: 30), schedule: shortFriday, cal: cal) ?? -1,
            0.5, "short Friday's own midpoint is 13:30"
        )

        // Basis inheritance: year → month → week → daily.
        var config = AppConfig()
        expect(config.resolvedMode(for: .year) == .workHours, "default chain resolves year to work hours")
        config.weekBasis = .calendar
        expect(config.resolvedMode(for: .month) == .calendar, "month 'like week' follows week to calendar")
        expect(config.resolvedMode(for: .year) == .calendar, "year 'like month' follows the chain to calendar")
        config.monthBasis = .daily
        expect(config.resolvedMode(for: .month) == .workHours, "month can break away with its own rule")
        expect(config.resolvedMode(for: .year) == .workHours, "year 'like month' follows month's own rule")
        config.yearBasis = .weekly
        expect(config.resolvedMode(for: .year) == .calendar, "year 'like week' skips past month")

        // Remaining workdays: from Wed (unfinished) to end of week = Wed, Thu, Fri.
        expect(
            ProgressEngine.remainingWorkdays(now: wednesday14, until: week.end, schedule: schedule, cal: cal) == 3,
            "Wed 14:00 leaves 3 workdays in the week"
        )
        expect(
            ProgressEngine.remainingWorkdays(now: weekDate(dayOffset: 2, hour: 19), until: week.end, schedule: schedule, cal: cal) == 2,
            "after Wed close of work, 2 workdays remain"
        )

        var empty = schedule
        for weekday in 1...7 {
            empty.setDay(weekday, DaySchedule(enabled: true, startMinute: 600, endMinute: 600))
        }
        expect(
            ProgressEngine.dayProgress(now: wednesday14, schedule: empty, cal: cal) == nil,
            "zero-length work window yields no day progress"
        )
        expectClose(
            ProgressEngine.rangeProgress(metric: .week, mode: .workHours, now: wednesday14, schedule: empty, cal: cal),
            0, "zero-length work window does not divide by zero"
        )

        let snap = ProgressEngine.snapshot(.today, now: weekDate(dayOffset: 2, hour: 14, minute: 40), config: AppConfig(), cal: cal)
        expect(snap.subtitle == "3h 20m left", "today subtitle formats time left (got \"\(snap.subtitle)\")")

        // Split-day slots: Monday works 11:00–12:00 and 14:00–15:00 only.
        var split = schedule
        split.setDay(2, DaySchedule(enabled: true, slots: [
            WorkSlot(startMinute: 11 * 60, endMinute: 12 * 60),
            WorkSlot(startMinute: 14 * 60, endMinute: 15 * 60),
        ]))
        expectClose(split.day(2).seconds, 2 * 3600, "split Monday totals 2h")
        expectClose(
            ProgressEngine.dayProgress(now: weekDate(dayOffset: 0, hour: 10, minute: 30), schedule: split, cal: cal) ?? -1,
            0, "before the first slot is 0%"
        )
        expectClose(
            ProgressEngine.dayProgress(now: weekDate(dayOffset: 0, hour: 12, minute: 30), schedule: split, cal: cal) ?? -1,
            0.5, "the break between slots holds at 50%"
        )
        expectClose(
            ProgressEngine.dayProgress(now: weekDate(dayOffset: 0, hour: 14, minute: 30), schedule: split, cal: cal) ?? -1,
            0.75, "midway through the second slot is 75%"
        )
        expectClose(
            ProgressEngine.dayProgress(now: weekDate(dayOffset: 0, hour: 16), schedule: split, cal: cal) ?? -1,
            1, "after the last slot is 100%"
        )
        let splitTally = ProgressEngine.workTally(now: wednesday14, from: week.start, to: week.end, schedule: split, cal: cal)
        expectClose(splitTally.total, 34 * 3600, "split Monday shrinks week to 34h", accuracy: 0.5)

        // Old saved configs (single start/end per day) decode into one slot.
        let legacyDay = #"{"enabled":true,"startMinute":600,"endMinute":1080}"#.data(using: .utf8)!
        let migratedDay = try? JSONDecoder().decode(DaySchedule.self, from: legacyDay)
        expect(migratedDay?.slots.count == 1, "old single-window day decodes into one slot")
        expectClose(migratedDay?.seconds ?? -1, 8 * 3600, "migrated day keeps its 8 hours")

        // Todos round-trip through the saved config.
        var todoConfig = AppConfig()
        todoConfig.todos = [TodoItem(text: "Ship it"), TodoItem(text: "Review PR", done: true)]
        let encoded = try? JSONEncoder().encode(todoConfig)
        let restored = encoded.flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
        expect(restored?.todos.count == 2, "todos survive save and load")
        expect(restored?.todos.first?.text == "Ship it", "todo text survives save and load")
        expect(restored?.todos.last?.done == true, "todo done state survives save and load")

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }
}
