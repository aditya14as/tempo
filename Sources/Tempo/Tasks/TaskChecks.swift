import Foundation

/// Self-checks for the Tasks tab's pure logic and its saved settings.
enum TaskChecks {
    private static let cal: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return cal
    }()

    private static func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// Wednesday 23 Sep 2026, 10:00 IST.
    private static let now = at(2026, 9, 23, 10, 0)

    static func run() {
        buckets()
        sections()
        stamping()
        clearing()
        moving()
        quickAdd()
        decoding()
    }

    // MARK: - Buckets and sections

    private static func buckets() {
        func bucket(_ due: Date?, done: Bool = false) -> TaskBucket {
            TaskLogic.bucket(TodoItem(text: "t", done: done, dueDate: due), now: now, cal: cal)
        }
        Checks.expect(bucket(at(2026, 9, 23, 8)) == .overdue, "due earlier today and open → overdue")
        Checks.expect(bucket(at(2026, 9, 22, 18)) == .overdue, "due yesterday → overdue")
        Checks.expect(bucket(at(2026, 9, 23, 23, 59)) == .today, "due later today → today")
        Checks.expect(bucket(at(2026, 9, 24, 0, 0)) == .upcoming, "due tomorrow → upcoming")
        Checks.expect(bucket(nil) == .someday, "no due date → no date")
        Checks.expect(bucket(at(2026, 9, 22), done: true) == .completed, "done → completed")
    }

    private static func sections() {
        let late = TodoItem(text: "late", dueDate: at(2026, 9, 22, 9))
        let todayLate = TodoItem(text: "today 17", dueDate: at(2026, 9, 23, 17))
        let todayEarly = TodoItem(text: "today 12", dueDate: at(2026, 9, 23, 12))
        let todayFlag = TodoItem(text: "today flagged", dueDate: at(2026, 9, 23, 20), flagged: true)
        let soon = TodoItem(text: "upcoming", dueDate: at(2026, 9, 30, 9))
        let a = TodoItem(text: "a")
        let b = TodoItem(text: "b")
        let c = TodoItem(text: "c flagged", flagged: true)
        let oldDone = TodoItem(text: "old done", done: true, completedAt: at(2026, 9, 20))
        let newDone = TodoItem(text: "new done", done: true, completedAt: at(2026, 9, 23, 9))
        let list = [a, oldDone, todayLate, b, late, todayEarly, soon, newDone, c, todayFlag]

        let grouped = TaskLogic.sections(list, grouped: true, now: now, cal: cal)
        Checks.expect(grouped.map(\.bucket) == [.overdue, .today, .upcoming, .someday, .completed],
            "sections come in Overdue/Today/Upcoming/No date/Completed order")
        Checks.expect(grouped[1].items.map(\.text) == ["today flagged", "today 12", "today 17"],
            "flagged first, then soonest due (got \(grouped[1].items.map(\.text)))")
        Checks.expect(grouped[3].items.map(\.text) == ["c flagged", "a", "b"],
            "undated tasks keep manual order after flagged ones")
        Checks.expect(grouped[4].items.map(\.text) == ["new done", "old done"],
            "completed tasks: most recently completed first")

        let onlyToday = TaskLogic.sections([todayLate], grouped: true, now: now, cal: cal)
        Checks.expect(onlyToday.map(\.bucket) == [.today], "empty sections are left out")

        let flat = TaskLogic.sections(list, grouped: false, now: now, cal: cal)
        Checks.expect(flat.map(\.bucket) == [.someday, .completed], "ungrouped: one open section plus Completed")
        Checks.expect(flat[0].items.map(\.text)
            == ["c flagged", "today flagged", "a", "today 17", "b", "late", "today 12", "upcoming"],
            "ungrouped: flagged first, otherwise manual order")

        let counts = TaskLogic.counts(list + [TodoItem(text: " ")])
        Checks.expect(counts.open == 8 && counts.done == 2, "counts skip blank rows")
    }

    // MARK: - Completion stamps and auto-clear

    private static func stamping() {
        let open = TodoItem(text: "x")
        var done = open
        done.done = true
        let stamped = TaskLogic.stampingCompletions([done], old: [open], now: now)
        Checks.expect(stamped.first?.completedAt == now, "checking a task off stamps completedAt")

        let earlier = at(2026, 9, 1)
        var kept = done
        kept.completedAt = earlier
        Checks.expect(TaskLogic.stampingCompletions([kept], old: [kept], now: now).first?.completedAt == earlier,
            "an already-stamped done task keeps its stamp")

        var reopened = kept
        reopened.done = false
        Checks.expect(TaskLogic.stampingCompletions([reopened], old: [kept], now: now).first?.completedAt == nil,
            "re-opening a task clears completedAt")

        let legacy = TodoItem(text: "legacy", done: true)
        Checks.expect(TaskLogic.stampingCompletions([legacy], old: [legacy], now: now).first?.completedAt == now,
            "legacy done tasks without a stamp get one")

        let dupes = TaskLogic.stampingCompletions([done], old: [open, open], now: now)
        Checks.expect(dupes.first?.completedAt == now, "duplicate ids in the old list don't crash")
    }

    private static func clearing() {
        func done(_ text: String, _ at: Date?) -> TodoItem {
            TodoItem(text: text, done: true, completedAt: at)
        }
        let list = [
            TodoItem(text: "open"),
            done("2h", now.addingTimeInterval(-2 * 3600)),
            done("2d", now.addingTimeInterval(-2 * 86_400)),
            done("10d", now.addingTimeInterval(-10 * 86_400)),
            done("40d", now.addingTimeInterval(-40 * 86_400)),
            done("unstamped", nil),
        ]
        func kept(_ rule: TaskAutoClear) -> [String] {
            TaskLogic.clearingExpired(list, rule: rule, now: now).map(\.text)
        }
        Checks.expect(kept(.never) == list.map(\.text), "auto-clear never keeps everything")
        Checks.expect(kept(.oneDay) == ["open", "2h", "unstamped"], "auto-clear after a day")
        Checks.expect(kept(.oneWeek) == ["open", "2h", "2d", "unstamped"], "auto-clear after a week")
        Checks.expect(kept(.oneMonth) == ["open", "2h", "2d", "10d", "unstamped"],
            "auto-clear after a month; unstamped done tasks are kept")
    }

    private static func moving() {
        let a = TodoItem(text: "a"), b = TodoItem(text: "b"), c = TodoItem(text: "c")
        let list = [a, b, c]
        func texts(_ l: [TodoItem]) -> [String] { l.map(\.text) }
        Checks.expect(texts(TaskLogic.moving(list, id: c.id, before: a.id)) == ["c", "a", "b"],
            "move a task before another")
        Checks.expect(texts(TaskLogic.moving(list, id: a.id, before: c.id)) == ["b", "a", "c"],
            "move a task down, before a later one")
        Checks.expect(texts(TaskLogic.moving(list, id: a.id, before: nil)) == ["b", "c", "a"],
            "move a task to the end")
        Checks.expect(TaskLogic.moving(list, id: UUID(), before: a.id) == list
            && TaskLogic.moving(list, id: a.id, before: UUID()) == list
            && TaskLogic.moving(list, id: a.id, before: a.id) == list,
            "unknown ids (or moving before itself) leave the list unchanged")
    }

    // MARK: - Quick add

    private static func quickAdd() {
        func parse(_ s: String) -> QuickAddResult { TaskLogic.parseQuickAdd(s, now: now, cal: cal) }

        let call = parse("Call mom tomorrow 3pm")
        Checks.expect(call.title == "Call mom" && call.dueDate == at(2026, 9, 24, 15) && !call.flagged,
            "\"Call mom tomorrow 3pm\" → Call mom, tomorrow 15:00 (got \(call))")
        let ship = parse("Ship it !")
        Checks.expect(ship.title == "Ship it" && ship.flagged && ship.dueDate == nil, "trailing ! flags")
        let fix = parse("! Fix bug")
        Checks.expect(fix.title == "Fix bug" && fix.flagged, "leading ! flags")
        let urgent = parse("Pay rent!!")
        Checks.expect(urgent.title == "Pay rent" && urgent.flagged, "!! flags too")
        let cheer = parse("Great job!")
        Checks.expect(cheer.title == "Great job!" && !cheer.flagged, "a lone attached ! is punctuation")
        Checks.expect(parse("Buy milk") == QuickAddResult(title: "Buy milk", dueDate: nil, flagged: false),
            "plain text stays as typed, no date")
        let review = parse("Review PR friday")
        Checks.expect(review.title == "Review PR" && review.dueDate == at(2026, 9, 25, 9),
            "date-only phrase gets 09:00 (got \(review))")
        let on = parse("Call mom on friday at 3pm")
        Checks.expect(on.title == "Call mom" && on.dueDate == at(2026, 9, 25, 15),
            "dangling \"on\" is tidied away (got \(on))")
        let onlyDate = parse("tomorrow")
        Checks.expect(onlyDate.title == "tomorrow" && onlyDate.dueDate == at(2026, 9, 24, 9),
            "a title that is only a date keeps its text")
        let name = parse("Email May")
        Checks.expect(name.title == "Email May" && name.dueDate == nil, "a bare month name isn't a date")
        let past = parse("Taxes Sep 1 2026")
        Checks.expect(past.title == "Taxes Sep 1 2026" && past.dueDate == nil, "a date in the past is ignored")
    }

    // MARK: - Saved format

    private static func decoding() {
        let id = UUID()
        let old = #"{"id":"\#(id.uuidString)","text":"Old task","done":true,"reminderID":"r1"}"#
        let item = try? JSONDecoder().decode(TodoItem.self, from: Data(old.utf8))
        Checks.expect(item?.id == id && item?.text == "Old task" && item?.done == true
            && item?.reminderID == "r1" && item?.flagged == false && item?.notes == nil && item?.completedAt == nil,
            "tasks saved before flags/notes/completedAt still decode")

        let garbage = #"[{"text":"good"},{"text":"weird","flagged":"yes please","notes":42}]"#
        let list = try? JSONDecoder().decode([TodoItem].self, from: Data(garbage.utf8))
        Checks.expect(list?.map(\.text) == ["good", "weird"] && list?.last?.flagged == false,
            "a garbage field doesn't drop the task (or the list)")

        let tasks = try? JSONDecoder().decode(TasksConfig.self, from: Data("{}".utf8))
        Checks.expect(tasks == TasksConfig() && tasks?.autoClear == .oneWeek && tasks?.groupByDue == true,
            "TasksConfig decodes defaults from {}")

        let config = #"{"todos":[{"id":"\#(UUID().uuidString)","text":"one","done":false},"#
            + #"{"id":"\#(UUID().uuidString)","text":"two","done":true,"dueDate":770000000}]}"#
        let decoded = try? JSONDecoder().decode(AppConfig.self, from: Data(config.utf8))
        Checks.expect(decoded?.todos.map(\.text) == ["one", "two"] && decoded?.tasks == TasksConfig(),
            "an old config keeps every task and gets default task settings")

        var roundTrip = AppConfig()
        roundTrip.todos = [TodoItem(text: "r", done: true, flagged: true, notes: "n", completedAt: now)]
        roundTrip.tasks.autoClear = .never
        let back = (try? JSONEncoder().encode(roundTrip)).flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
        Checks.expect(back?.todos == roundTrip.todos && back?.tasks.autoClear == .never,
            "new task fields and settings survive save and load")
    }
}
