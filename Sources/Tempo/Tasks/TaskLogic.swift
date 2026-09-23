import Foundation

// MARK: - Tasks tab logic (pure, covered by --check)

/// Where an open task sits in the Tasks tab.
enum TaskBucket: String, CaseIterable, Identifiable {
    case overdue, today, upcoming, someday, completed

    var id: String { rawValue }
    var label: String {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .someday: return "No date"
        case .completed: return "Completed"
        }
    }
}

struct TaskSection: Identifiable, Equatable {
    var bucket: TaskBucket
    var items: [TodoItem]
    var id: String { bucket.rawValue }
}

/// What the quick-add field turns typed text into.
struct QuickAddResult: Equatable {
    var title: String
    var dueDate: Date?
    var flagged: Bool
}

enum TaskLogic {
    /// The Tasks tab's sections, in display order. Empty sections are left out.
    /// - Open tasks: grouped (Overdue/Today/Upcoming/No date) when `grouped`,
    ///   else one `.someday`-bucketed section holding every open task.
    ///   Within a section: flagged first, then (dated buckets) soonest due,
    ///   then the user's manual order (array order) — the sort is stable.
    /// - Done tasks: one `.completed` section, most recently completed first.
    static func sections(_ todos: [TodoItem], grouped: Bool, now: Date, cal: Calendar) -> [TaskSection] {
        let indexed = Array(todos.enumerated())
        let open = indexed.filter { !$0.element.done }
        let done = indexed.filter { $0.element.done }
        var result: [TaskSection] = []

        func ordered(_ items: [(offset: Int, element: TodoItem)], byDue: Bool) -> [TodoItem] {
            items.sorted { a, b in
                if a.element.flagged != b.element.flagged { return a.element.flagged }
                if byDue {
                    let da = a.element.dueDate ?? .distantFuture, db = b.element.dueDate ?? .distantFuture
                    if da != db { return da < db }
                }
                return a.offset < b.offset
            }.map(\.element)
        }

        if grouped {
            for bucket in [TaskBucket.overdue, .today, .upcoming, .someday] {
                let items = open.filter { self.bucket($0.element, now: now, cal: cal) == bucket }
                if !items.isEmpty {
                    result.append(TaskSection(bucket: bucket, items: ordered(items, byDue: bucket != .someday)))
                }
            }
        } else if !open.isEmpty {
            result.append(TaskSection(bucket: .someday, items: ordered(open, byDue: false)))
        }

        if !done.isEmpty {
            let items = done.sorted { a, b in
                let ca = a.element.completedAt ?? .distantPast, cb = b.element.completedAt ?? .distantPast
                return ca != cb ? ca > cb : a.offset < b.offset
            }.map(\.element)
            result.append(TaskSection(bucket: .completed, items: items))
        }
        return result
    }

    /// Which bucket an open task falls in (done tasks → `.completed`).
    static func bucket(_ todo: TodoItem, now: Date, cal: Calendar) -> TaskBucket {
        if todo.done { return .completed }
        guard let due = todo.dueDate else { return .someday }
        if due < now { return .overdue }
        return cal.isDate(due, inSameDayAs: now) ? .today : .upcoming
    }

    /// Stamps `completedAt = now` on tasks that became done since `old`
    /// (and on done tasks missing a stamp, e.g. saved before it existed);
    /// clears it on tasks that were re-opened.
    static func stampingCompletions(_ todos: [TodoItem], old: [TodoItem], now: Date) -> [TodoItem] {
        let oldDone = Dictionary(old.map { ($0.id, $0.done) }, uniquingKeysWith: { first, _ in first })
        return todos.map { todo in
            var todo = todo
            if todo.done {
                if todo.completedAt == nil || oldDone[todo.id] == false { todo.completedAt = now }
            } else if todo.completedAt != nil {
                todo.completedAt = nil
            }
            return todo
        }
    }

    /// Drops done tasks completed longer ago than `rule` keeps them.
    static func clearingExpired(_ todos: [TodoItem], rule: TaskAutoClear, now: Date) -> [TodoItem] {
        guard let keep = rule.keep else { return todos }
        return todos.filter { todo in
            guard todo.done, let completed = todo.completedAt else { return true }
            return now.timeIntervalSince(completed) <= keep
        }
    }

    /// Manual reorder: moves task `id` to sit just before `target`
    /// (nil = to the end). Unknown ids leave the list unchanged.
    static func moving(_ todos: [TodoItem], id: UUID, before target: UUID?) -> [TodoItem] {
        guard id != target, let from = todos.firstIndex(where: { $0.id == id }) else { return todos }
        if let target, !todos.contains(where: { $0.id == target }) { return todos }
        var list = todos
        let item = list.remove(at: from)
        if let target, let to = list.firstIndex(where: { $0.id == target }) {
            list.insert(item, at: to)
        } else {
            list.append(item)
        }
        return list
    }

    /// Parses the quick-add field: a leading "!" (or a spaced/doubled trailing one) flags the task,
    /// and a natural-language date ("tomorrow 3pm", "fri 9:30", "in 2 hours")
    /// becomes the due date and is removed from the title. A date-only
    /// phrase ("tomorrow") gets 09:00. Titles that are only a date keep the text.
    static func parseQuickAdd(_ text: String, now: Date, cal: Calendar) -> QuickAddResult {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var flagged = false
        if body.hasPrefix("!") {
            flagged = true
            body = String(body.drop(while: { $0 == "!" }))
        }
        // A trailing "!" only flags when it stands apart ("Ship it !") or is
        // doubled ("Pay rent!!"), so "Great job!" stays plain punctuation.
        let bangs = body.reversed().prefix(while: { $0 == "!" }).count
        if bangs > 0 {
            let rest = body.dropLast(bangs)
            if bangs >= 2 || rest.last?.isWhitespace == true {
                flagged = true
                body = String(rest)
            }
        }
        body = tidy(body)
        guard !body.isEmpty else { return QuickAddResult(title: text, dueDate: nil, flagged: false) }

        guard let (range, due) = detectDate(in: body, now: now, cal: cal) else {
            return QuickAddResult(title: body, dueDate: nil, flagged: flagged)
        }
        let ns = body as NSString
        let before = tidy(ns.substring(to: range.location), trailing: true)
        let after = tidy(ns.substring(from: range.location + range.length), leading: true)
        let title = tidy([before, after].filter { !$0.isEmpty }.joined(separator: " "))
        return QuickAddResult(title: title.isEmpty ? body : title, dueDate: due, flagged: flagged)
    }

    /// "3 left · 2 done" style counts for the header.
    static func counts(_ todos: [TodoItem]) -> (open: Int, done: Int) {
        (todos.filter { !$0.done && !$0.isBlank }.count, todos.filter(\.done).count)
    }

    // MARK: - Quick-add date helpers

    /// Glue words left hanging once a date phrase is cut out ("Call mom on").
    private static let danglers: Set<String> = ["at", "on", "by", "due", "for", "@", "-", ",", "until", "before"]
    private static let weekdayWords = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
    ]
    private static let monthWords = [
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    ]
    private static let relativeWords = ["today", "tonight", "tomorrow", "tmrw", "next", "noon", "midnight"]
    private static let timeWords = ["am", "pm", "noon", "midnight", "tonight", "morning", "afternoon", "evening", "lunch"]

    /// Collapses whitespace and strips dangling glue words from the ends.
    private static func tidy(_ s: String, leading: Bool = false, trailing: Bool = false) -> String {
        var words = s.split(whereSeparator: \.isWhitespace).map(String.init)
        while trailing, let last = words.last, danglers.contains(last.lowercased()) { words.removeLast() }
        while leading, let first = words.first, danglers.contains(first.lowercased()) { words.removeFirst() }
        var out = words.joined(separator: " ")
        while trailing, out.hasSuffix(",") { out.removeLast() }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasWord(_ phrase: String, _ words: [String]) -> Bool {
        let tokens = Set(phrase.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        return words.contains(where: tokens.contains)
    }

    private static func matches(_ phrase: String, _ pattern: String) -> Bool {
        phrase.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The first believable, not-past date phrase in `text`, re-anchored on
    /// `now`/`cal` (NSDataDetector always reads relative to the real clock).
    private static func detectDate(in text: String, now: Date, cal: Calendar) -> (NSRange, Date)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let realNow = Date()
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let detected = match.date, match.range.length >= 3 else { continue }
            let phrase = ns.substring(with: match.range)
            // A bare month name ("May") is more likely a name than a date.
            let clearlyDate = phrase.contains(where: \.isNumber)
                || hasWord(phrase, weekdayWords + relativeWords + timeWords)
            guard clearlyDate,
                let due = anchored(detected, phrase: phrase, realNow: realNow, now: now, cal: cal),
                due >= now
            else { continue }
            return (match.range, due)
        }
        return nil
    }

    /// Moves the detector's answer onto `now`'s timeline in `cal`, keeping
    /// the wall-clock time the user typed (or 09:00 when they gave none).
    private static func anchored(_ detected: Date, phrase: String, realNow: Date, now: Date, cal: Calendar) -> Date? {
        if matches(phrase, #"\bin\s+(an?|\d+)\s+(min|minute|hour|hr|day|week)"#) {
            return now.addingTimeInterval(detected.timeIntervalSince(realNow))
        }
        let sys = Calendar.current
        let wall = sys.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: detected)
        let hasTime = matches(phrase, #"\d:\d\d|\d\s*(am|pm)\b|\bat\s+\d"#) || hasWord(phrase, timeWords)
        let hour = hasTime ? wall.hour ?? 9 : 9
        let minute = hasTime ? wall.minute ?? 0 : 0

        let day: Date?
        if hasWord(phrase, monthWords) || matches(phrase, #"\d{1,4}[/.-]\d{1,2}"#) {
            day = cal.date(from: DateComponents(year: wall.year, month: wall.month, day: wall.day))
        } else {
            let realOffset = sys.dateComponents([.day], from: sys.startOfDay(for: realNow),
                                                to: sys.startOfDay(for: detected)).day ?? 0
            var offset = realOffset
            if hasWord(phrase, weekdayWords), let weekday = wall.weekday {
                // Same weekday as the detector picked, same number of weeks out.
                let realDelta = (weekday - sys.component(.weekday, from: realNow) + 7) % 7
                let delta = (weekday - cal.component(.weekday, from: now) + 7) % 7
                offset = delta + max(0, (realOffset - realDelta) / 7) * 7
            }
            day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now))
        }
        guard let day else { return nil }
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}
