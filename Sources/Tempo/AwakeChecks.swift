import Foundation

/// Self-checks for the keep-awake planning logic (no IOKit involved).
enum AwakeChecks {
    static func run() {
        let cal = ProgressEngine.mondayCalendar
        let schedule = WorkSchedule()  // Mon–Fri 10:00–18:00
        func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        let wed14 = at(2026, 5, 13, 14)  // a Wednesday
        let sat14 = at(2026, 5, 16, 14)

        Checks.expect(AwakePlanner.end(afterMinutes: 90, from: wed14) == wed14.addingTimeInterval(5400),
            "a 90-minute session ends 90 minutes out")
        Checks.expect(AwakePlanner.workEnd(on: wed14, schedule: schedule, cal: cal) == at(2026, 5, 13, 18),
            "'until work ends' is today's 18:00")
        Checks.expect(AwakePlanner.workEnd(on: at(2026, 5, 13, 19), schedule: schedule, cal: cal) == nil,
            "no 'until work ends' after hours")
        Checks.expect(AwakePlanner.workEnd(on: sat14, schedule: schedule, cal: cal) == nil,
            "no 'until work ends' on a day off")
        Checks.expect(AwakePlanner.inWorkHours(wed14, schedule: schedule, cal: cal)
            && !AwakePlanner.inWorkHours(at(2026, 5, 13, 9, 59), schedule: schedule, cal: cal)
            && !AwakePlanner.inWorkHours(at(2026, 5, 13, 18), schedule: schedule, cal: cal)
            && !AwakePlanner.inWorkHours(sat14, schedule: schedule, cal: cal),
            "work hours cover 10:00 up to (not including) 18:00 on workdays only")

        var triggers = AwakeTriggers()
        var env = AwakeEnvironment()
        Checks.expect(AwakePlanner.triggerReason(triggers, env: env, now: wed14, schedule: schedule, cal: cal) == nil,
            "no triggers configured, no auto session")
        triggers.externalDisplay = true
        env.externalDisplay = true
        Checks.expect(AwakePlanner.triggerReason(triggers, env: env, now: sat14, schedule: schedule, cal: cal)
            == "External display connected", "an external display trigger fires")
        triggers.apps = [AppRef(bundleID: "com.apple.dt.Xcode", name: "Xcode")]
        env.runningBundleIDs = ["com.apple.dt.Xcode"]
        Checks.expect(AwakePlanner.triggerReason(triggers, env: env, now: sat14, schedule: schedule, cal: cal)
            == "Xcode is open", "an app trigger names the app")
        triggers.enabled = false
        Checks.expect(AwakePlanner.triggerReason(triggers, env: env, now: sat14, schedule: schedule, cal: cal) == nil,
            "pausing auto silences every trigger")
        var power = AwakeTriggers()
        power.onPower = true
        Checks.expect(AwakePlanner.triggerReason(power, env: AwakeEnvironment(onAC: true, hasBattery: false),
            now: wed14, schedule: schedule, cal: cal) == nil,
            "'plugged in' never fires on a desktop Mac with no battery")
        var work = AwakeTriggers()
        work.workHours = true
        Checks.expect(AwakePlanner.triggerReason(work, env: AwakeEnvironment(), now: wed14, schedule: schedule, cal: cal)
            == "Work hours", "the work-hours trigger follows Tempo's schedule")

        var config = AwakeConfig()
        let onBattery = AwakeEnvironment(onAC: false, hasBattery: true, batteryPercent: 12)
        Checks.expect(AwakePlanner.batteryStop(config, env: onBattery) == "Battery below 15%",
            "a low battery ends the session")
        Checks.expect(AwakePlanner.batteryStop(config, env: AwakeEnvironment(onAC: true, hasBattery: true, batteryPercent: 5))
            == nil, "a low battery on power is fine")
        config.endOnLowBattery = false
        Checks.expect(AwakePlanner.batteryStop(config, env: onBattery) == nil, "the low-battery guard can be turned off")
        config.endWhenUnplugged = true
        Checks.expect(AwakePlanner.batteryStop(config, env: onBattery) == "Unplugged from power",
            "'stop when unplugged' ends the session on battery")

        Checks.expect(AwakePlanner.remaining(35) == "35s" && AwakePlanner.remaining(61) == "2m"
            && AwakePlanner.remaining(3600) == "1h 00m" && AwakePlanner.remaining(7_500) == "2h 05m",
            "time-left labels round up to the next minute")
        Checks.expect(AwakePlanner.menuBarRemaining(2520) == "42m" && AwakePlanner.menuBarRemaining(7_500) == "2h05",
            "menu bar time-left is compact")
        Checks.expect(AwakePlanner.durationLabel(30) == "30m" && AwakePlanner.durationLabel(120) == "2h"
            && AwakePlanner.durationLabel(90) == "1h 30m", "preset chips read naturally")
        Checks.expect(AwakePlanner.nextOccurrence(ofTimeIn: at(2000, 1, 1, 17, 30), after: wed14, cal: cal)
            == at(2026, 5, 13, 17, 30), "'until 17:30' later today stays today")
        Checks.expect(AwakePlanner.nextOccurrence(ofTimeIn: at(2000, 1, 1, 9), after: wed14, cal: cal)
            == at(2026, 5, 14, 9), "'until 09:00' already past rolls to tomorrow")
    }
}
