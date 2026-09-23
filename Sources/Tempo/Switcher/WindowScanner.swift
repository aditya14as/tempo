import AppKit
import ApplicationServices

/// One entry in the switcher: a window, or a running app with no windows.
struct SwitchItem: Identifiable {
    var id: String
    var pid: pid_t
    var wid: CGWindowID
    var appName: String
    var bundleID: String?
    var title: String
    var isMinimized = false
    var isHidden = false
    var isWindowless = false
    /// Window frame in top-left-origin screen coordinates (AX / CG convention).
    var frame: CGRect = .zero
    /// Space number when the window lives on another Space (for the badge).
    var spaceNumber: Int?
    /// Nil for windows only the window server knows about (other Spaces).
    var element: AXUIElement?

    var bucket: SwitcherLogic.Bucket {
        if isWindowless { return .windowless }
        if isMinimized { return .minimized }
        if isHidden { return .hidden }
        return .normal
    }

    var displayTitle: String { title.isEmpty ? appName : title }
}

/// Builds the window list and acts on windows. Everything that talks to other
/// apps over Accessibility is time-boxed: a hung app is skipped, never waited on.
enum WindowScanner {
    private static let perAppTimeout: Float = 0.25
    /// Off the main thread, so a slow app can have a little longer.
    private static let scanBudget: TimeInterval = 0.3

    /// Windows of every regular app, filtered by the switcher settings, plus
    /// the frontmost app's focused window. `onlyPID` limits the scan to one
    /// app (the ⌥` mode). The Accessibility calls run off the main thread —
    /// an app that's been idle can take a while to answer — and `completion`
    /// gets the result on the main thread, with the apps that didn't answer
    /// in time in `late`.
    @MainActor
    static func scan(
        config: SwitcherConfig, onlyPID: pid_t? = nil,
        completion: @escaping @MainActor (_ result: ScanResult) -> Void
    ) {
        let hidden = Set(config.hiddenApps.map(\.bundleID))
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.processIdentifier != getpid()
                && !app.isTerminated
                && !hidden.contains(app.bundleIdentifier ?? "")
                && (onlyPID == nil || app.processIdentifier == onlyPID)
        }
        let infos = apps.map { AppInfo(pid: $0.processIdentifier, name: $0.localizedName ?? "App",
                                       bundleID: $0.bundleIdentifier, hidden: $0.isHidden) }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        DispatchQueue.global(qos: .userInteractive).async {
            let focused = frontPID.map { focusedWindowID(pid: $0) } ?? 0
            var result = collect(infos, config: config, onlyPID: onlyPID)
            result.focused = focused
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    struct ScanResult {
        var items: [SwitchItem]
        var late: Set<pid_t>
        var focused: CGWindowID = 0
    }

    private static func collect(_ infos: [AppInfo], config: SwitcherConfig, onlyPID: pid_t?) -> ScanResult {
        // Scan apps in parallel; take whatever has arrived when the budget runs out.
        let box = ResultBox()
        let group = DispatchGroup()
        for info in infos {
            group.enter()
            DispatchQueue.global(qos: .userInteractive).async {
                let windows = axWindows(of: info)
                box.add(info.pid, windows)
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + scanBudget)
        let byPID = box.close()

        let spaces = PrivateAPIs.spaceSnapshot()
        var items: [SwitchItem] = []
        var seen = Set<CGWindowID>()
        for info in infos {
            guard let windows = byPID[info.pid] else { continue }
            for var item in windows {
                if item.isMinimized && !config.showMinimized { continue }
                if info.hidden && !config.showHidden { continue }
                if item.wid != 0 { seen.insert(item.wid) }
                item.spaceNumber = otherSpaceNumber(item.wid, spaces)
                if config.scope == .currentSpace, item.spaceNumber != nil { continue }
                items.append(item)
            }
        }

        if config.scope == .allSpaces, let spaces {
            items += otherSpaceWindows(apps: infos, known: seen, spaces: spaces)
        }

        // Apps that are running but show nothing get one tile at the end.
        if onlyPID == nil {
            let withWindows = Set(items.map(\.pid))
            for info in infos where !withWindows.contains(info.pid) && byPID[info.pid] != nil {
                if info.hidden && !config.showHidden { continue }
                items.append(SwitchItem(
                    id: "app-\(info.pid)", pid: info.pid, wid: 0, appName: info.name,
                    bundleID: info.bundleID, title: info.name, isHidden: info.hidden, isWindowless: true
                ))
            }
        }
        let late = Set(infos.map(\.pid).filter { byPID[$0] == nil })
        return ScanResult(items: items, late: late)
    }

    struct AppInfo: Sendable {
        var pid: pid_t
        var name: String
        var bundleID: String?
        var hidden: Bool
    }

    /// Collects per-app results from the scan threads; late arrivals after
    /// `close()` are dropped.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [pid_t: [SwitchItem]] = [:]
        private var closed = false

        func add(_ pid: pid_t, _ items: [SwitchItem]) {
            lock.lock()
            if !closed { results[pid] = items }
            lock.unlock()
        }

        func close() -> [pid_t: [SwitchItem]] {
            lock.lock()
            defer { lock.unlock() }
            closed = true
            return results
        }
    }

    private static func axWindows(of info: AppInfo) -> [SwitchItem] {
        let app = AXUIElementCreateApplication(info.pid)
        AXUIElementSetMessagingTimeout(app, perAppTimeout)
        guard let windows = copy(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        var items: [SwitchItem] = []
        for window in windows {
            let title = clean(copy(window, kAXTitleAttribute) as? String ?? "")
            let subrole = copy(window, kAXSubroleAttribute) as? String
            let frame = self.frame(of: window)
            guard SwitcherLogic.isRealWindow(subrole: subrole, title: title, size: frame.size) else { continue }
            let wid = PrivateAPIs.windowID(of: window)
            let minimized = copy(window, kAXMinimizedAttribute) as? Bool ?? false
            items.append(SwitchItem(
                id: wid != 0 ? "w\(wid)" : "p\(info.pid)-\(items.count)",
                pid: info.pid, wid: wid, appName: info.name, bundleID: info.bundleID,
                title: title, isMinimized: minimized, isHidden: info.hidden, frame: frame, element: window
            ))
        }
        return items
    }

    /// A 1-based Space number if the window sits on a Space that isn't showing.
    private static func otherSpaceNumber(_ wid: CGWindowID, _ spaces: PrivateAPIs.SpaceSnapshot?) -> Int? {
        guard let spaces, wid != 0 else { return nil }
        let on = PrivateAPIs.spaces(of: wid)
        guard !on.isEmpty, spaces.current.isDisjoint(with: on) else { return nil }
        return on.compactMap { spaces.number[$0] }.min()
    }

    /// Windows on other Spaces: AX only lists the current Space's windows for
    /// most apps, but the window server knows them all. Focusable through the
    /// private front-process call, which also switches to their Space.
    private static func otherSpaceWindows(
        apps: [AppInfo], known: Set<CGWindowID>, spaces: PrivateAPIs.SpaceSnapshot
    ) -> [SwitchItem] {
        guard PrivateAPIs.setFrontProcess != nil,
            let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let byPID = Dictionary(apps.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [SwitchItem] = []
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t, let app = byPID[pid],
                let wid = entry[kCGWindowNumber as String] as? CGWindowID, !known.contains(wid),
                (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict),
                bounds.width >= 100, bounds.height >= 50
            else { continue }
            let on = PrivateAPIs.spaces(of: wid)
            guard !on.isEmpty, spaces.current.isDisjoint(with: on), let number = on.compactMap({ spaces.number[$0] }).min()
            else { continue }
            let name = clean(entry[kCGWindowName as String] as? String ?? "")
            items.append(SwitchItem(
                id: "w\(wid)", pid: pid, wid: wid, appName: app.name, bundleID: app.bundleID,
                title: name, isHidden: app.hidden, frame: bounds, spaceNumber: number
            ))
        }
        return items
    }

    // MARK: - Current window

    static func focusedWindowID(pid: pid_t) -> CGWindowID {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, perAppTimeout)
        guard let value = copy(element, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return 0 }
        return PrivateAPIs.windowID(of: value as! AXUIElement)
    }

    /// Top-left-origin frames of on-screen windows, front to back — seeds the
    /// recency order before Tempo has seen anything get focus.
    static func onScreenOrder() -> [CGWindowID] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            (entry[kCGWindowLayer as String] as? Int) == 0 ? entry[kCGWindowNumber as String] as? CGWindowID : nil
        }
    }

    // MARK: - Actions

    /// Brings the item's window (or app) forward, un-minimizing and un-hiding
    /// as needed.
    @MainActor
    static func focus(_ item: SwitchItem, cursorFollows: Bool) {
        guard let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        if item.isWindowless {
            if let url = app.bundleURL {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                app.activate()
            }
            return
        }
        if app.isHidden { app.unhide() }
        if let element = item.element, item.isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        let fronted = PrivateAPIs.makeFrontAndKey(pid: item.pid, wid: item.wid)
        if let element = item.element {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if !fronted {
            app.activate()
        }
        if cursorFollows {
            let frame = item.element.map(self.frame(of:)) ?? item.frame
            warpCursor(into: frame)
        }
    }

    /// Moves the pointer to the middle of `frame` unless it's already inside.
    private static func warpCursor(into frame: CGRect) {
        guard frame.width > 0, let primary = NSScreen.screens.first else { return }
        let mouse = NSEvent.mouseLocation  // bottom-left origin
        let mouseTopLeft = CGPoint(x: mouse.x, y: primary.frame.maxY - mouse.y)
        guard !frame.contains(mouseTopLeft) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }

    static func close(_ item: SwitchItem) {
        guard let element = item.element,
            let button = copy(element, kAXCloseButtonAttribute), CFGetTypeID(button) == AXUIElementGetTypeID()
        else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
    }

    static func toggleMinimize(_ item: SwitchItem) {
        guard let element = item.element else { return }
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString,
                                     item.isMinimized ? kCFBooleanFalse : kCFBooleanTrue)
    }

    @MainActor
    static func toggleHide(_ item: SwitchItem) {
        guard let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        _ = app.isHidden ? app.unhide() : app.hide()
    }

    @MainActor
    static func quit(_ item: SwitchItem) {
        NSRunningApplication(processIdentifier: item.pid)?.terminate()
    }

    /// Titles arrive with stray padding and invisible direction marks (WhatsApp's "\u{200E}WhatsApp").
    static func clean(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202C}")))
    }

    // MARK: - AX plumbing

    static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    static func frame(of element: AXUIElement) -> CGRect {
        var origin = CGPoint.zero
        var size = CGSize.zero
        if let value = copy(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgPoint, &origin)
        }
        if let value = copy(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() {
            AXValueGetValue(value as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: origin, size: size)
    }
}

/// Remembers which windows were used most recently: app activations, window
/// focus changes inside each app (one AXObserver per app), and every switch
/// Tempo makes itself.
@MainActor
final class RecencyTracker {
    static let shared = RecencyTracker()
    private(set) var order: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        order = WindowScanner.onScreenOrder()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app else { return }
                RecencyTracker.shared.observe(app)
                RecencyTracker.shared.appActivated(app.processIdentifier)
            }
        }
        ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let pid = app?.processIdentifier, let observer = RecencyTracker.shared.observers.removeValue(forKey: pid)
                else { return }
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app)
        }
    }

    func note(_ wid: CGWindowID) {
        order = SwitcherLogic.noteFocused(wid, in: order)
    }

    private func appActivated(_ pid: pid_t) {
        // Read the newly active app's focused window off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let wid = WindowScanner.focusedWindowID(pid: pid)
            DispatchQueue.main.async { MainActor.assumeIsolated { RecencyTracker.shared.note(wid) } }
        }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil, pid != getpid(), app.activationPolicy == .regular else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, _, _ in
            let wid = PrivateAPIs.windowID(of: element)
            MainActor.assumeIsolated { RecencyTracker.shared.note(wid) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }
}
