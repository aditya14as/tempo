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

        // Wi-Fi and USB triggers
        var nets = AwakeTriggers()
        nets.wifiNetworks = ["Office"]
        Checks.expect(AwakePlanner.triggerReason(nets, env: AwakeEnvironment(wifiSSID: "Office"), now: sat14,
            schedule: schedule, cal: cal) == "On Office Wi-Fi", "a listed Wi-Fi network keeps the Mac awake")
        Checks.expect(AwakePlanner.triggerReason(nets, env: AwakeEnvironment(wifiSSID: "Cafe"), now: sat14,
            schedule: schedule, cal: cal) == nil
            && AwakePlanner.triggerReason(nets, env: AwakeEnvironment(), now: sat14, schedule: schedule, cal: cal) == nil,
            "another network, or no visible network, doesn't")
        var usb = AwakeTriggers()
        usb.usbDevices = [USBDeviceRef(vendorID: 0x046d, productID: 0xc52b, name: "Unifying Receiver")]
        Checks.expect(usb.usbDevices[0].id == "1133:50475" && usb.anyConfigured && usb.ruleCount == 1,
            "a USB rule is keyed by vendor:product and counts as a rule")
        Checks.expect(AwakePlanner.triggerReason(usb, env: AwakeEnvironment(usbDeviceIDs: ["1133:50475"]), now: sat14,
            schedule: schedule, cal: cal) == "Unifying Receiver connected", "a plugged-in USB device fires its rule")
        Checks.expect(AwakePlanner.triggerReason(usb, env: AwakeEnvironment(usbDeviceIDs: ["1:2"]), now: sat14,
            schedule: schedule, cal: cal) == nil, "an unlisted USB device doesn't")

        // Long sessions and date-and-time ends
        let gb = Locale(identifier: "en_GB")
        Checks.expect(AwakePlanner.clock(at(2026, 5, 13, 18, 5), cal: cal, locale: Locale(identifier: "en_US")) == "6:05\u{202F}PM"
            && AwakePlanner.clock(at(2026, 5, 13, 18, 5), cal: cal, locale: gb) == "18:05",
            "times follow the 12- or 24-hour clock setting")
        Checks.expect(AwakePlanner.remaining(26 * 3600) == "1d 2h" && AwakePlanner.menuBarRemaining(26 * 3600) == "1d2h",
            "sessions over a day show days")
        Checks.expect(AwakePlanner.untilLabel(at(2026, 5, 13, 18), now: wed14, cal: cal, locale: gb) == "18:00",
            "an end later today is just a time")
        Checks.expect(AwakePlanner.untilLabel(at(2026, 5, 14, 9), now: wed14, cal: cal, locale: gb) == "tomorrow 09:00",
            "an end tomorrow says so")
        let farLabel = AwakePlanner.untilLabel(at(2026, 5, 16, 9, 30), now: wed14, cal: cal, locale: gb)
        Checks.expect(farLabel == "Sat 16 May 09:30",
            "an end days away names the day (got \(farLabel))")
        Checks.expect(AwakePlanner.combine(day: at(2026, 5, 20, 3), time: at(2000, 1, 1, 17, 45), cal: cal)
            == at(2026, 5, 20, 17, 45), "a picked day and a picked time merge into one moment")

        // Closed-lid sudo rule
        Checks.expect(ClosedLid.sudoersLine(user: "aditya")
            == "aditya ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0",
            "the sudo rule allows exactly the two pmset commands")
        Checks.expect(ClosedLid.sudoersLine(user: "a b") == nil && ClosedLid.sudoersLine(user: "x,ALL") == nil
            && ClosedLid.sudoersLine(user: "") == nil, "odd account names never reach sudoers")

        // Cursor nudge
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        Checks.expect(CursorNudger.lastRealInput(eventAt: t0.addingTimeInterval(60.3), lastNudge: t0.addingTimeInterval(60),
            previous: t0) == t0, "our own nudge doesn't count as you being back")
        Checks.expect(CursorNudger.lastRealInput(eventAt: t0.addingTimeInterval(90), lastNudge: t0.addingTimeInterval(60),
            previous: t0) == t0.addingTimeInterval(90), "real input after a nudge does")
        Checks.expect(!CursorNudger.shouldNudge(realIdle: 59, sinceLastNudge: 1_000, interval: 60)
            && CursorNudger.shouldNudge(realIdle: 60, sinceLastNudge: 1_000, interval: 60)
            && !CursorNudger.shouldNudge(realIdle: 90, sinceLastNudge: 30, interval: 60)
            && CursorNudger.shouldNudge(realIdle: 130, sinceLastNudge: 60, interval: 60),
            "the pointer moves once per interval of idleness, never while you're busy")

        // Drive Alive
        let a = DriveRef(id: "A", name: "Backup", path: "/Volumes/Backup")
        let b = DriveRef(id: "B", name: "Media", path: "/Volumes/Media")
        var drives = AwakeConfig()
        Checks.expect(DriveKeeper.targets(drives, mounted: [a, b]).isEmpty, "Drive Alive off touches nothing")
        drives.driveAlive = true
        Checks.expect(DriveKeeper.targets(drives, mounted: [a, b]) == [a, b], "no drives picked means every external drive")
        drives.drives = [b, DriveRef(id: "C", name: "Gone", path: "/Volumes/Gone")]
        Checks.expect(DriveKeeper.targets(drives, mounted: [a, b]) == [b], "picked drives only, and only if mounted")
    }
}
