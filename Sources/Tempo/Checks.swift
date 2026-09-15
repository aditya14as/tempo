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

        var empty = schedule
        empty.endMinute = empty.startMinute
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

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }
}
