import AppKit
import Foundation

/// Self-checks for the progress math, run with `Tempo --check`.
/// Command Line Tools ship no XCTest/Testing module, so tests live here as
/// plain assertions executed before the app would launch.
enum Checks {
    private static var failures = 0

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            print("  ok  \(label)")
        } else {
            failures += 1
            print("FAIL  \(label)")
        }
    }

    static func expectClose(_ a: Double, _ b: Double, _ label: String, accuracy: Double = 0.0001) {
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

        // Due dates: labels, overdue flag, and which tasks earn a notification.
        func exact(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
        }
        let wedNow = exact(2026, 5, 13, 14, 0)  // Wednesday 13 May 2026, 14:00
        expect(
            DueFormat.label(exact(2026, 5, 13, 15, 30), now: wedNow, cal: cal) == "Today 15:30",
            "same-day due reads Today HH:mm"
        )
        expect(
            DueFormat.label(exact(2026, 5, 14, 9, 5), now: wedNow, cal: cal) == "Tomorrow 09:05",
            "next-day due reads Tomorrow HH:mm"
        )
        expect(
            DueFormat.label(exact(2026, 5, 22, 17, 0), now: wedNow, cal: cal) == "Fri 22 May 17:00",
            "far due reads weekday day month time (got \"\(DueFormat.label(exact(2026, 5, 22, 17, 0), now: wedNow, cal: cal))\")"
        )
        expect(
            DueFormat.isOverdue(exact(2026, 5, 13, 13, 0), now: wedNow, done: false),
            "past due and not done is overdue"
        )
        expect(
            !DueFormat.isOverdue(exact(2026, 5, 13, 13, 0), now: wedNow, done: true),
            "a finished task is never overdue"
        )
        expect(
            !DueFormat.isOverdue(exact(2026, 5, 13, 15, 0), now: wedNow, done: false),
            "future due is not overdue"
        )
        let futureDue = exact(2026, 5, 13, 16, 0)
        let reminderPool = [
            TodoItem(text: "done already", done: true, dueDate: futureDue),
            TodoItem(text: "no due date"),
            TodoItem(text: "already fired", dueDate: exact(2026, 5, 13, 12, 0)),
            TodoItem(text: "ok", dueDate: futureDue),
            TodoItem(text: "   ", dueDate: futureDue),
        ]
        let pending = DueFormat.pendingReminders(reminderPool, now: wedNow)
        expect(
            pending.count == 1 && pending.first?.text == "ok",
            "only unfinished, future-due, non-empty tasks get a notification"
        )
        let comps = DueFormat.triggerComponents(exact(2026, 5, 13, 15, 30), cal: cal)
        expect(
            comps.year == 2026 && comps.month == 5 && comps.day == 13
                && comps.hour == 15 && comps.minute == 30,
            "notification trigger keys on exact date and minute"
        )

        // Dropped files and links become tasks.
        let fileDrop = TodoItem.fromDroppedURL(URL(fileURLWithPath: "/tmp/report.pdf"))
        expect(fileDrop.text == "report.pdf", "dropped file names the task after the file")
        expect(fileDrop.link == "/tmp/report.pdf", "dropped file keeps its full path")
        expect(fileDrop.linkName == "report.pdf", "file chip shows just the file name")
        expect(fileDrop.linkURL?.isFileURL == true, "dropped file opens as a file URL")
        let webDrop = TodoItem.fromDroppedURL(URL(string: "https://github.com/aditya14as/tempo")!)
        expect(webDrop.link == "https://github.com/aditya14as/tempo", "dropped link keeps the full URL")
        expect(webDrop.linkName == "github.com", "link chip shows the site name")

        // Due date and attachment survive save and load.
        var fullConfig = AppConfig()
        fullConfig.todos = [TodoItem(text: "Review", dueDate: futureDue, link: "/tmp/report.pdf")]
        let fullData = try? JSONEncoder().encode(fullConfig)
        let fullBack = fullData.flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
        expect(
            abs((fullBack?.todos.first?.dueDate?.timeIntervalSince(futureDue)) ?? 999) < 1,
            "due date survives save and load"
        )
        expect(fullBack?.todos.first?.link == "/tmp/report.pdf", "attachment survives save and load")

        // One-tap due presets.
        expect(
            QuickDue.tonight(wedNow, cal: cal) == exact(2026, 5, 13, 18, 0),
            "Tonight preset lands on today 18:00"
        )
        expect(
            QuickDue.tomorrowMorning(wedNow, schedule: schedule, cal: cal) == exact(2026, 5, 14, 10, 0),
            "Tomorrow preset lands on tomorrow's work start"
        )
        expect(
            QuickDue.nextMonday(wedNow, schedule: schedule, cal: cal) == exact(2026, 5, 18, 10, 0),
            "Next Monday preset lands on Mon 18 May 10:00"
        )
        expect(
            QuickDue.inTwoHours(exact(2026, 5, 13, 14, 0), cal: cal) == exact(2026, 5, 13, 16, 0),
            "In-2h preset from a round hour stays round"
        )
        expect(
            QuickDue.inTwoHours(exact(2026, 5, 13, 14, 7), cal: cal) == exact(2026, 5, 13, 16, 15),
            "In-2h preset snaps up to the next quarter hour"
        )

        // Week glance: tasks group onto their due day, agenda sorts by time.
        let glancePool = [
            TodoItem(text: "late", dueDate: exact(2026, 5, 14, 16, 0)),
            TodoItem(text: "early", dueDate: exact(2026, 5, 14, 9, 0)),
            TodoItem(text: "other day", dueDate: exact(2026, 5, 15, 9, 0)),
            TodoItem(text: "undated"),
        ]
        let thursday = DueFormat.tasks(glancePool, dueOn: exact(2026, 5, 14, 0, 0), cal: cal)
        expect(
            thursday.map(\.text) == ["early", "late"],
            "a day's tasks filter to that day and sort by time"
        )
        expect(
            DueFormat.agenda(glancePool).map(\.text) == ["early", "late", "other day"],
            "agenda lists only dated tasks, soonest first"
        )

        // Shelf items: file vs link mapping, and they survive save and load.
        let shelfFile = ShelfItem.fromDroppedURL(URL(fileURLWithPath: "/tmp/deck.key"))
        expect(shelfFile.isFile && shelfFile.name == "deck.key", "shelf file keeps path and short name")
        let shelfLink = ShelfItem.fromDroppedURL(URL(string: "https://github.com/aditya14as/tempo")!)
        expect(!shelfLink.isFile && shelfLink.name == "github.com", "shelf link keeps URL and site name")
        var shelfConfig = AppConfig()
        shelfConfig.shelf = [shelfFile, shelfLink]
        let shelfData = try? JSONEncoder().encode(shelfConfig)
        let shelfBack = shelfData.flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
        expect(
            shelfBack?.shelf.map(\.link) == ["/tmp/deck.key", "https://github.com/aditya14as/tempo"],
            "shelf survives save and load"
        )

        // Two-way Apple Reminders sync: their completed-state wins on pull.
        let syncPool = [
            TodoItem(text: "finish there", done: false, reminderID: "r1"),
            TodoItem(text: "reopen there", done: true, reminderID: "r2"),
            TodoItem(text: "deleted there", done: false, reminderID: "r3"),
            TodoItem(text: "never exported", done: false),
        ]
        let merged = DueFormat.applyingCompletions(syncPool, ["r1": true, "r2": false])
        expect(
            merged.map(\.done) == [true, false, false, false],
            "reminders completions apply both ways and skip missing/unexported"
        )
        expect(
            DueFormat.applyingCompletions(syncPool, [:]) == syncPool,
            "an empty completions map changes nothing"
        )

        // Notification identifiers carry the task's UUID.
        let noteTodo = TodoItem(text: "ping me")
        expect(
            ReminderScheduler.todoID(fromNotificationID: "tempo.todo." + noteTodo.id.uuidString) == noteTodo.id,
            "notification id round-trips back to the task id"
        )
        expect(
            ReminderScheduler.todoID(fromNotificationID: "other.thing") == nil,
            "foreign notification ids are ignored"
        )

        // reminderID survives save and load.
        var syncConfig = AppConfig()
        syncConfig.todos = [TodoItem(text: "exported", reminderID: "abc-123")]
        let syncData = try? JSONEncoder().encode(syncConfig)
        let syncBack = syncData.flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
        expect(syncBack?.todos.first?.reminderID == "abc-123", "reminder link survives save and load")

        // Abandoned "+" rows count as blank; anything meaningful does not.
        expect(TodoItem(text: "").isBlank, "an untouched new row is blank")
        expect(TodoItem(text: "   ").isBlank, "a spaces-only row is blank")
        expect(!TodoItem(text: "real task").isBlank, "typed text keeps the row")
        expect(!TodoItem(text: "", dueDate: futureDue).isBlank, "a set due time keeps the row")
        expect(!TodoItem(text: "", link: "/tmp/a.pdf").isBlank, "an attachment keeps the row")

        // Yesterday's saved todos (no due/link fields) still decode.
        let oldTodo = #"{"id":"6F1C1C1E-2A2B-4C4D-8E8F-101112131415","text":"old","done":false}"#.data(using: .utf8)!
        let decodedOld = try? JSONDecoder().decode(TodoItem.self, from: oldTodo)
        expect(decodedOld?.text == "old" && decodedOld?.dueDate == nil && decodedOld?.link == nil,
               "todos saved before this feature still load")

        // Drops from editors arrive as plain text — paths and links must parse.
        expect(
            DroppedURLs.url(fromString: "/Users/x/report.pdf")?.path == "/Users/x/report.pdf",
            "an absolute path drop becomes a file URL"
        )
        expect(
            DroppedURLs.url(fromString: "file:///tmp/a%20b.txt")?.path == "/tmp/a b.txt",
            "a file:// drop decodes its escapes"
        )
        expect(
            DroppedURLs.url(fromString: "https://apple.com")?.scheme == "https",
            "a web link drop stays a web link"
        )
        expect(
            DroppedURLs.url(fromString: "~/notes.txt")?.path.hasSuffix("/notes.txt") == true
                && DroppedURLs.url(fromString: "~/notes.txt")?.path.hasPrefix("/") == true,
            "a ~ path expands to the home folder"
        )
        expect(DroppedURLs.url(fromString: "   ") == nil, "blank text is not a drop")
        expect(DroppedURLs.url(fromString: "hello world") == nil, "plain words are not a drop")
        expect(
            DroppedURLs.urls(fromText: "file:///tmp/a.txt\nfile:///tmp/b.txt").count == 2,
            "a two-line uri list yields two files"
        )
        expect(
            DroppedURLs.urls(fromText: "junk\n/tmp/real.txt").map(\.path) == ["/tmp/real.txt"],
            "junk lines are skipped, real paths kept"
        )

        let shelfAB = [ShelfItem(link: "/a"), ShelfItem(link: "/b")]
        expect(
            ShelfItem.merged(shelf: shelfAB, dropped: [URL(fileURLWithPath: "/new")])
                .map(\.link) == ["/new", "/a", "/b"],
            "a dropped file lands at the front of the shelf"
        )
        expect(
            ShelfItem.merged(shelf: shelfAB, dropped: [URL(fileURLWithPath: "/b")])
                .map(\.link) == ["/b", "/a"],
            "re-dropping a file moves it to the front, no duplicate"
        )
        expect(
            ShelfItem.merged(shelf: shelfAB, dropped: [URL(fileURLWithPath: "/c")], cap: 2)
                .map(\.link) == ["/c", "/a"],
            "a full shelf drops its oldest item to fit a new one"
        )

        // Builds the little-endian blob Chromium uses for drag data:
        // payload size, entry count, then UTF-16 key/value pairs padded
        // to 4-byte boundaries. Mirrors Chromium's Pickle writer.
        func pickle(_ entries: [(String, String)]) -> Data {
            var payload = Data()
            func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { payload.append(contentsOf: $0) } }
            func put(_ s: String) {
                let units = Array(s.utf16)
                put(UInt32(units.count))
                units.withUnsafeBytes { payload.append(contentsOf: $0) }
                while payload.count % 4 != 0 { payload.append(0) }
            }
            put(UInt32(entries.count))
            for (key, value) in entries {
                put(key)
                put(value)
            }
            var out = Data()
            withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
            out.append(payload)
            return out
        }

        expect(
            ChromiumWebCustomData.urls(fromPickle: pickle([("text/plain", "/tmp/pickle.txt")]))
                .map(\.path) == ["/tmp/pickle.txt"],
            "a chromium pickle with a path yields that file"
        )
        expect(
            ChromiumWebCustomData.urls(fromPickle: pickle([
                ("x-conductor/thing", "whatever"),
                ("text/uri-list", "file:///tmp/from%20list.txt"),
            ])).map(\.path) == ["/tmp/from list.txt"],
            "a chromium pickle prefers its uri list"
        )
        expect(
            ChromiumWebCustomData.urls(fromPickle: Data([9, 9, 9])).isEmpty,
            "a garbage pickle yields nothing"
        )

        // A Conductor-style drop: promise types present but a real path in
        // the plain text. The text must win — promises are a dead end there.
        let fake = NSPasteboard(name: NSPasteboard.Name("tempo-check-\(UUID().uuidString)"))
        fake.declareTypes(
            [
                NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
                NSPasteboard.PasteboardType("Apple files promise pasteboard type"),
                DropPayload.webCustomData,
                .string,
            ], owner: nil
        )
        fake.setString("/tmp/conductor-style.py", forType: .string)
        expect(
            DropPayload.urls(from: fake).map(\.path) == ["/tmp/conductor-style.py"],
            "a promise-plus-text drop takes the text path"
        )
        fake.releaseGlobally()

        // Where the drag card pops. Cocoa coords on a 1710x1112 notch display:
        // 38pt menu bar, Dock hidden, so the usable area tops out at 1074.
        let card = NSSize(width: 264, height: 236)
        let screen = NSRect(x: 0, y: 0, width: 1710, height: 1112)
        let visible = NSRect(x: 0, y: 0, width: 1710, height: 1074)
        // A drag picked up inside a window (pointer not in the bar): centred,
        // clear of the top edge.
        let below = ShelfPlacement.topLeft(cardSize: card, cursor: NSPoint(x: 400, y: 600), screen: screen, visible: visible)
        expect(
            below.spot == .belowBar && below.point == NSPoint(x: 723, y: 1030),
            "an in-window drag pops the card centred, 44pt below the menu bar"
        )
        // A drag up in the menu bar: card under the pointer, over the bar, top
        // at the very top of the screen so the cursor is already on it.
        let over = ShelfPlacement.topLeft(cardSize: card, cursor: NSPoint(x: 1000, y: 1090), screen: screen, visible: visible)
        expect(
            over.spot == .overBar && over.point == NSPoint(x: 868, y: 1112)
                && over.point.x <= 1000 && over.point.x + card.width >= 1000,
            "a drag in the menu bar puts the card under the pointer and over the bar"
        )
        // The one-point sliver a maximized window leaves below the bar counts as
        // the bar (so a Zed drag that just exited upward is caught).
        let sliver = ShelfPlacement.topLeft(cardSize: card, cursor: NSPoint(x: 1000, y: 1073.5), screen: screen, visible: visible)
        expect(sliver.spot == .overBar, "the sliver between a maximized window and the bar counts as the bar")
        // Near the screen edge the over-bar card stays on-screen and still spans the pointer.
        let edge = ShelfPlacement.topLeft(cardSize: card, cursor: NSPoint(x: 1700, y: 1090), screen: screen, visible: visible)
        expect(
            edge.spot == .overBar && edge.point.x == 1438 && edge.point.x + card.width <= visible.maxX - 8 + 0.001,
            "an over-bar card near the right edge stays fully on-screen"
        )
        // After a drop, an over-bar card settles flush under the bar; one below stays put.
        expect(
            ShelfPlacement.settledTop(currentTop: 1112, visible: visible) == 1074
                && ShelfPlacement.settledTop(currentTop: 1030, visible: visible) == 1030,
            "after a drop a card over the bar drops flush under it; one already below stays"
        )

        // Awake + Switcher settings round-trip, and a saved config from before
        // they existed still decodes (with defaults).
        var featured = AppConfig()
        featured.awake.allowDisplaySleep = true
        featured.awake.presets = [15, 45]
        featured.awake.toggleShortcut = KeyCombo(keyCode: 0, modifiers: [.control, .option])
        featured.awake.triggers.apps = [AppRef(bundleID: "com.apple.Music", name: "Music")]
        featured.awake.session = AwakeSession(kind: .until(Date(timeIntervalSince1970: 1_800_000_000)))
        featured.switcher.modifier = .control
        featured.switcher.style = .titles
        featured.switcher.hiddenApps = [AppRef(bundleID: "com.apple.Terminal", name: "Terminal")]
        featured.awake.closedLid = true
        featured.awake.moveCursor = true
        featured.awake.moveCursorMinutes = 4
        featured.awake.driveAlive = true
        featured.awake.drives = [DriveRef(id: "UUID-1", name: "Backup", path: "/Volumes/Backup")]
        featured.awake.triggers.wifiNetworks = ["Office"]
        featured.awake.triggers.usbDevices = [USBDeviceRef(vendorID: 1, productID: 2, name: "Dock")]
        featured.features.tasks = false
        featured.features.shelf = false
        let featuredBack = (try? JSONEncoder().encode(featured)).flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
        expect(featuredBack == featured, "awake, switcher and feature settings survive save and load")
        var toggled = AppConfig()
        toggled.set(.switcher, on: false)
        toggled.set(.workHours, on: false)
        expect(!toggled.isOn(.switcher) && !toggled.switcher.enabled && !toggled.isOn(.workHours)
            && toggled.isOn(.tasks) && toggled.isOn(.awake) && toggled.isOn(.shelf),
            "feature switches flip exactly one feature each")
        let oldJSON = #"{"awake":{"allowDisplaySleep":true,"triggers":{"onPower":true}}}"#
        let old = try? JSONDecoder().decode(AppConfig.self, from: Data(oldJSON.utf8))
        expect(old?.awake.allowDisplaySleep == true && old?.awake.triggers.onPower == true
            && old?.features == FeatureSet() && old?.awake.closedLid == false && old?.awake.triggers.wifiNetworks == [],
            "a config saved before Features and the new Awake options loads with everything on")
        expect(featuredBack?.awake.toggleShortcut?.label == "⌃⌥A", "shortcut label renders modifiers then key")
        expect(
            featuredBack?.awake.session?.endsAt == Date(timeIntervalSince1970: 1_800_000_000),
            "a timed awake session keeps its end time"
        )
        let preFeature = "{\"theme\":\"ocean\",\"awake\":{\"presets\":[5]},\"switcher\":{\"style\":\"bogus\"}}"
        let partial = try? JSONDecoder().decode(AppConfig.self, from: Data(preFeature.utf8))
        expect(partial?.theme == .ocean && partial?.awake.presets == [5], "partial awake settings keep what was saved")
        expect(partial?.awake.notifyOnEnd == true && partial?.switcher.style == .thumbnails,
            "missing or bad awake/switcher keys fall back to defaults")
        expect(!KeyCombo(keyCode: 0, modifiers: []).isUsable && KeyCombo(keyCode: 122, modifiers: []).isUsable,
            "a bare letter is not a usable shortcut; a bare function key is")

        AwakeChecks.run()
        SwitcherChecks.run()
        ClipboardChecks.run()
        TaskChecks.run()

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")
        return failures == 0 ? 0 : 1
    }
}
