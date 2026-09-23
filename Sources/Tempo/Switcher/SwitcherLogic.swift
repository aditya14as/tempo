import CoreGraphics
import Foundation

/// The pure rules behind the switcher — which windows count, their order,
/// the starting pick, keyboard movement, and grid sizing. No AppKit or AX
/// here, so `--check` can pin all of it down.
enum SwitcherLogic {
    // MARK: Which windows are real

    /// AltTab's admission rules, simplified: standard windows always; titled
    /// dialogs; anything else only if it is titled, reasonably big, and not a
    /// floating palette or system dialog.
    static func isRealWindow(subrole: String?, title: String, size: CGSize) -> Bool {
        let titled = !title.trimmingCharacters(in: .whitespaces).isEmpty
        let bigEnough = size.width >= 100 && size.height >= 50
        switch subrole {
        case "AXStandardWindow":
            return bigEnough || titled
        case "AXDialog":
            return titled
        case "AXFloatingWindow", "AXSystemDialog", "AXSystemFloatingWindow":
            return false
        default:
            return titled && bigEnough
        }
    }

    // MARK: Order

    enum Bucket: Int, Comparable {
        case normal = 0, hidden, minimized, windowless
        static func < (a: Bucket, b: Bucket) -> Bool { a.rawValue < b.rawValue }
    }

    /// Most recently used first; windows Tempo has never seen focused keep
    /// their scan order after the known ones. Hidden, then minimized, then
    /// windowless apps go to the end (AltTab's "show at the end").
    static func order<T>(_ items: [T], wid: (T) -> CGWindowID, bucket: (T) -> Bucket, mru: [CGWindowID]) -> [T] {
        var rank: [CGWindowID: Int] = [:]
        for (i, id) in mru.enumerated() where rank[id] == nil { rank[id] = i }
        return items.enumerated().sorted { a, b in
            let ba = bucket(a.element), bb = bucket(b.element)
            if ba != bb { return ba < bb }
            let ra = rank[wid(a.element)] ?? Int.max
            let rb = rank[wid(b.element)] ?? Int.max
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Moves `wid` to the front of the recency list.
    static func noteFocused(_ wid: CGWindowID, in mru: [CGWindowID], cap: Int = 200) -> [CGWindowID] {
        guard wid != 0 else { return mru }
        var next = mru.filter { $0 != wid }
        next.insert(wid, at: 0)
        if next.count > cap { next.removeLast(next.count - cap) }
        return next
    }

    /// Start on the previous window (index 1) when the first entry is the
    /// window you're in now — a quick ⌥⇥ flips between the last two.
    static func initialSelection(count: Int, firstIsCurrent: Bool) -> Int {
        guard count > 1 else { return 0 }
        return firstIsCurrent ? 1 : 0
    }

    // MARK: Keyboard movement

    /// ±1 along the list; wraps on a fresh press, stops at the ends while a
    /// key is auto-repeating (so holding ⇥ can't spin past what you meant).
    static func step(_ index: Int, count: Int, by delta: Int, isRepeat: Bool) -> Int {
        guard count > 0 else { return 0 }
        let next = index + delta
        if next >= 0 && next < count { return next }
        if isRepeat { return min(max(next, 0), count - 1) }
        return ((next % count) + count) % count
    }

    /// Up/down one row in a grid with `columns` per row, keeping the column
    /// (clamped into a short last row). Wraps top↔bottom unless repeating.
    static func rowMove(_ index: Int, count: Int, columns: Int, by delta: Int, isRepeat: Bool) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        let rows = (count + columns - 1) / columns
        guard rows > 1 else { return index }
        let column = index % columns
        var row = index / columns + delta
        if row < 0 || row >= rows {
            if isRepeat { return index }
            row = ((row % rows) + rows) % rows
        }
        return min(row * columns + column, count - 1)
    }

    // MARK: Grid sizing

    /// How many cards of `cardWidth` fit across `maxWidth`, never more than `count`.
    static func columns(count: Int, cardWidth: CGFloat, spacing: CGFloat, maxWidth: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        let fit = Int(((maxWidth + spacing) / (cardWidth + spacing)).rounded(.down))
        return max(1, min(count, fit))
    }

    /// Steps the card size down (from the chosen one) until everything fits
    /// in `maxRows`; returns the smallest if nothing does (the grid scrolls).
    static func fittingSize(
        count: Int, preferred: SwitcherSize, maxRows: Int, maxWidth: CGFloat, spacing: CGFloat,
        width: (SwitcherSize) -> CGFloat
    ) -> SwitcherSize {
        let ladder: [SwitcherSize] = [.large, .medium, .small]
        let start = ladder.firstIndex(of: preferred) ?? 1
        for size in ladder[start...] {
            let cols = columns(count: count, cardWidth: width(size), spacing: spacing, maxWidth: maxWidth)
            if (count + cols - 1) / cols <= maxRows { return size }
        }
        return .small
    }
}
