import CoreGraphics
import Foundation

/// Self-checks for the switcher's pure logic.
enum SwitcherChecks {
    static func run() {
        let big = CGSize(width: 800, height: 600)
        let tiny = CGSize(width: 40, height: 20)
        Checks.expect(SwitcherLogic.isRealWindow(subrole: "AXStandardWindow", title: "", size: big),
            "an untitled standard window still counts")
        Checks.expect(!SwitcherLogic.isRealWindow(subrole: "AXFloatingWindow", title: "Colors", size: big),
            "floating palettes are left out")
        Checks.expect(SwitcherLogic.isRealWindow(subrole: "AXDialog", title: "Save", size: tiny)
            && !SwitcherLogic.isRealWindow(subrole: "AXDialog", title: "", size: big),
            "dialogs count only when titled")
        Checks.expect(!SwitcherLogic.isRealWindow(subrole: "AXUnknown", title: "strip", size: tiny)
            && SwitcherLogic.isRealWindow(subrole: nil, title: "Game", size: big),
            "custom windows count when titled and window-sized")

        struct W { var wid: CGWindowID; var bucket: SwitcherLogic.Bucket }
        let list = [W(wid: 1, bucket: .minimized), W(wid: 2, bucket: .normal), W(wid: 3, bucket: .normal),
                    W(wid: 0, bucket: .windowless), W(wid: 4, bucket: .hidden), W(wid: 5, bucket: .normal)]
        let ordered = SwitcherLogic.order(list, wid: \.wid, bucket: \.bucket, mru: [3, 1, 2])
        Checks.expect(ordered.map(\.wid) == [3, 2, 5, 4, 1, 0],
            "recent windows lead; unseen keep scan order; hidden, minimized, windowless trail")
        Checks.expect(SwitcherLogic.noteFocused(2, in: [1, 2, 3]) == [2, 1, 3]
            && SwitcherLogic.noteFocused(0, in: [1]) == [1], "focusing moves a window to the front")

        Checks.expect(SwitcherLogic.initialSelection(count: 5, firstIsCurrent: true) == 1
            && SwitcherLogic.initialSelection(count: 5, firstIsCurrent: false) == 0
            && SwitcherLogic.initialSelection(count: 1, firstIsCurrent: true) == 0,
            "a quick ⌥⇥ lands on the previous window")

        Checks.expect(SwitcherLogic.step(4, count: 5, by: 1, isRepeat: false) == 0
            && SwitcherLogic.step(0, count: 5, by: -1, isRepeat: false) == 4, "a fresh press wraps around")
        Checks.expect(SwitcherLogic.step(4, count: 5, by: 1, isRepeat: true) == 4
            && SwitcherLogic.step(0, count: 5, by: -1, isRepeat: true) == 0, "a held key stops at the ends")

        // 7 cards in rows of 3: [0 1 2] [3 4 5] [6]
        Checks.expect(SwitcherLogic.rowMove(1, count: 7, columns: 3, by: 1, isRepeat: false) == 4,
            "down keeps the column")
        Checks.expect(SwitcherLogic.rowMove(5, count: 7, columns: 3, by: 1, isRepeat: false) == 6,
            "down into a short last row clamps to its end")
        Checks.expect(SwitcherLogic.rowMove(6, count: 7, columns: 3, by: 1, isRepeat: false) == 0
            && SwitcherLogic.rowMove(6, count: 7, columns: 3, by: 1, isRepeat: true) == 6,
            "down from the last row wraps, but not while repeating")
        Checks.expect(SwitcherLogic.rowMove(2, count: 3, columns: 3, by: 1, isRepeat: false) == 2,
            "a single row ignores up/down")

        Checks.expect(SwitcherLogic.columns(count: 10, cardWidth: 232, spacing: 10, maxWidth: 1200) == 5
            && SwitcherLogic.columns(count: 2, cardWidth: 232, spacing: 10, maxWidth: 1200) == 2
            && SwitcherLogic.columns(count: 3, cardWidth: 300, spacing: 10, maxWidth: 100) == 1,
            "columns fit the width and never exceed the card count")
        let width: (SwitcherSize) -> CGFloat = SwitcherMetrics.cardWidth
        Checks.expect(SwitcherLogic.fittingSize(count: 6, preferred: .large, maxRows: 3, maxWidth: 1200,
                                                spacing: 10, width: width) == .large,
            "few windows keep the chosen size")
        Checks.expect(SwitcherLogic.fittingSize(count: 14, preferred: .large, maxRows: 3, maxWidth: 1200,
                                                spacing: 10, width: width) == .medium,
            "more windows step the cards down a size")
        Checks.expect(SwitcherLogic.fittingSize(count: 80, preferred: .medium, maxRows: 3, maxWidth: 1200,
                                                spacing: 10, width: width) == .small,
            "a crowd bottoms out at small and scrolls")

        Checks.expect(WindowScanner.clean("\u{200E}WhatsApp  ") == "WhatsApp", "window titles lose padding and direction marks")

        var config = SwitcherConfig()
        config.modifier = .command
        config.hiddenApps = [AppRef(bundleID: "com.apple.Notes", name: "Notes")]
        config.hoverSelects = false
        let back = (try? JSONEncoder().encode(config)).flatMap { try? JSONDecoder().decode(SwitcherConfig.self, from: $0) }
        Checks.expect(back == config, "switcher settings survive save and load")

        // Info only: which private window-server symbols resolved on this macOS.
        for (name, ok) in PrivateAPIs.resolution {
            print("  info \(name): \(ok ? "resolved" : "MISSING")")
        }
    }
}
