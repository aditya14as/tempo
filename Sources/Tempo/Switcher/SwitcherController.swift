import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import os

/// The ⌥⇥ switcher's brain.
///
/// Trigger: `SwitcherTrigger`, an event tap on its own thread that catches
/// hold+⇥ (and hold+` for "this app's windows"). Before Accessibility is
/// allowed a Carbon hot key stands in, so the shortcut can point the way to
/// Settings. Once a session is open, a second event tap takes over: it
/// swallows every key the switcher uses, watches for the hold key's release,
/// and handles the mouse.
/// A 30 ms poll of the real modifier state backs up the release in case an
/// event is ever dropped — a missed release must never strand the panel.
@MainActor
final class SwitcherController: ObservableObject {
    static let shared = SwitcherController()

    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    let model = SwitcherModel()
    private weak var store: ConfigStore?
    private var config = SwitcherConfig()
    private var panel: SwitcherPanel?
    private var hosting: NSHostingView<SwitcherView>?
    private var hotKeys: [EventHotKeyRef] = []
    private var carbonHandler: EventHandlerRef?
    private var tap: CFMachPort?
    /// Listen-only tap for pointer moves, so hover never holds up the cursor.
    private var moveTap: CFMachPort?
    /// A click opened a window: keep eating events until its mouse-up, so the
    /// release doesn't land on whatever sits under the pointer.
    private var swallowMouseUp = false
    private var session: Session?
    private var pollTimer: Timer?
    private var permissionTimer: Timer?
    private var configObservation: AnyCancellable?
    private var disabledSymbolicKeys: [Int32] = []
    /// Keeps App Nap away while the switcher is on: a napping menu-bar app
    /// answers the first ⌥⇥ late, with its show timer coalesced.
    private var noNap: NSObjectProtocol?
    /// The last full scan. ⌥⇥ opens on it at once while a fresh scan runs:
    /// an app that's been idle can take a moment to answer Accessibility.
    private var cache: [SwitchItem] = []
    private var sessionCount = 0
    private var warmPending = false
    /// The trigger tap is catching the shortcut; the Carbon hot key isn't needed.
    private var triggerRunning = false
    private let log = Logger(subsystem: "com.ivy.tempo", category: "switcher")

    private struct Session {
        var id: Int
        var started = CACurrentMediaTime()
        var appOnly: Bool
        /// Opened from the menu: stays up until a click, ↩ or ⎋.
        var stayOpen: Bool
        var shown = false
        var shiftDown = false
        var mouseAnchor: CGPoint
        var hoverArmed = false
        var swallowedMouseDown = false
        /// The card a mouse-down landed on; the click opens it on mouse-up.
        var pressedIndex: Int?
        /// A window list is in (cached or scanned), so the session can show or commit.
        var loaded = false
        /// The show delay ran out before anything was loaded.
        var showDue = false
        /// Released before anything was loaded: commit once the scan lands.
        var commitOnLoad = false
        /// The selection was moved by a key, hover, or click; a fresh scan keeps it.
        var userMoved = false

        var elapsedMS: Int { Int((CACurrentMediaTime() - started) * 1000) }
    }

    nonisolated static let signature: OSType = 0x5453_5754  // 'TSWT'
    private static let tabKey: UInt16 = 48
    private static let graveKey: UInt16 = 50

    // MARK: Lifecycle

    func start(store: ConfigStore) {
        guard self.store == nil else { return }
        self.store = store
        installCarbonHandler()
        configObservation = store.$config
            .map(\.switcher)
            .removeDuplicates()
            .sink { config in
                DispatchQueue.main.async { MainActor.assumeIsolated { SwitcherController.shared.apply(config) } }
            }
        apply(store.config.switcher)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { SwitcherController.shared.restoreSystemShortcuts() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { SwitcherController.shared.warmCache() } }

        // Accessibility can be granted at any moment; pick it up without a relaunch.
        checkPermission()
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { SwitcherController.shared.checkPermission() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    private func checkPermission() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityGranted {
            accessibilityGranted = trusted
            registerHotKeys()
        }
        guard trusted else { return }
        if !triggerRunning, SwitcherTrigger.shared.start() {
            triggerRunning = true
            registerHotKeys()
            log.notice("trigger tap running")
        }
        RecencyTracker.shared.start()
        if tap == nil { createTap() }
        if cache.isEmpty { warmCache() }
    }

    /// Refreshes the cached window list in the background after the user
    /// switches apps, so the next ⌥⇥ opens on an up-to-date list.
    private func warmCache() {
        guard config.enabled, accessibilityGranted, !warmPending else { return }
        warmPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.warmPending = false
            guard self.session == nil else { return }
            WindowScanner.scan(config: self.config) { [weak self] result in
                guard let self else { return }
                self.cache = self.merged(result)
            }
        }
    }

    /// A scan's windows, with the cached ones of apps that didn't answer in time.
    private func merged(_ result: WindowScanner.ScanResult) -> [SwitchItem] {
        guard !result.late.isEmpty else { return result.items }
        return result.items + cache.filter { result.late.contains($0.pid) }
    }

    private func apply(_ config: SwitcherConfig) {
        let old = self.config
        self.config = config
        if session != nil, old.modifier != config.modifier || !config.enabled { cancel() }
        registerHotKeys()
        SwitcherTrigger.shared.configure(enabled: config.enabled, modifier: config.modifier,
                                         appWindowsKey: config.appWindowsKey)
        model.theme = store?.config.theme ?? .aurora
        if config.enabled, noNap == nil {
            noNap = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Window switcher responds instantly to its shortcut"
            )
        } else if !config.enabled, let activity = noNap {
            ProcessInfo.processInfo.endActivity(activity)
            noNap = nil
        }
    }

    /// Opens the switcher without holding a key (from the panel's footer).
    func showFromMenu() {
        begin(appOnly: false, stayOpen: true)
    }

    // MARK: Hot keys

    private func installCarbonHandler() {
        guard carbonHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard hotKeyID.signature == SwitcherController.signature else { return OSStatus(eventNotHandledErr) }
            let appOnly = hotKeyID.id == 2
            let latency = GetCurrentEventTime() - GetEventTime(event)
            MainActor.assumeIsolated { SwitcherController.shared.hotKeyPressed(appOnly: appOnly, latency: latency) }
            return noErr
        }, 1, &spec, nil, &carbonHandler)
    }

    private func registerHotKeys() {
        unregisterHotKeys()
        restoreSystemShortcuts()
        guard config.enabled, session == nil else { return }
        if config.modifier == .command {
            // Take ⌘⇥ (and ⌘` when used) away from the system while Tempo owns it.
            var ids: [Int32] = [1, 2]
            if config.appWindowsKey { ids.append(27) }
            for id in ids where PrivateAPIs.setSymbolicHotKey(id, enabled: false) { disabledSymbolicKeys.append(id) }
        }
        guard !triggerRunning else { return }
        let mods: UInt32
        switch config.modifier {
        case .option: mods = UInt32(optionKey)
        case .control: mods = UInt32(controlKey)
        case .command: mods = UInt32(cmdKey)
        }
        var keys: [(UInt16, UInt32)] = [(Self.tabKey, 1)]
        if config.appWindowsKey { keys.append((Self.graveKey, 2)) }
        for (code, id) in keys {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), mods, EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { hotKeys.append(ref) }
        }
    }

    private func unregisterHotKeys() {
        for ref in hotKeys { UnregisterEventHotKey(ref) }
        hotKeys.removeAll()
    }

    func restoreSystemShortcuts() {
        for id in disabledSymbolicKeys { PrivateAPIs.setSymbolicHotKey(id, enabled: true) }
        disabledSymbolicKeys.removeAll()
    }

    /// The trigger tap caught the shortcut.
    func triggered(appOnly: Bool, latency: TimeInterval) {
        log.notice("trigger appOnly=\(appOnly) reached main after \(Int(latency * 1000)) ms")
        if session == nil { begin(appOnly: appOnly, stayOpen: false) }
        SwitcherTrigger.shared.setActive(session != nil)
    }

    private func hotKeyPressed(appOnly: Bool, latency: TimeInterval) {
        log.notice("hotkey appOnly=\(appOnly) delivered after \(Int(latency * 1000)) ms")
        if session != nil {
            move(by: 1, isRepeat: false)
            return
        }
        guard accessibilityGranted else {
            Permissions.askAccessibility()
            return
        }
        begin(appOnly: appOnly, stayOpen: false)
    }

    // MARK: Session

    private func begin(appOnly: Bool, stayOpen: Bool) {
        guard session == nil, let store else { return }
        if tap == nil { createTap() }
        guard tap != nil else { return }
        setTaps(enabled: true)
        unregisterHotKeys()
        SwitcherTrigger.shared.setActive(true)
        sessionCount += 1
        let id = sessionCount
        session = Session(id: id, appOnly: appOnly, stayOpen: stayOpen, mouseAnchor: NSEvent.mouseLocation)

        let onlyPID = appOnly ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        model.theme = store.config.theme
        model.style = config.style
        model.showHints = config.showKeyHints
        model.showSpaceBadges = config.showSpaceBadges
        model.previewsOn = config.previews && config.style == .thumbnails && PreviewStore.shared.available
        model.hovered = nil
        model.images = PreviewStore.shared.cache
        model.items = []
        model.selected = 0

        // Open on the last scan straight away; the fresh one replaces it in a moment.
        let cached = cache.filter { item in
            (onlyPID == nil || item.pid == onlyPID)
                && NSRunningApplication(processIdentifier: item.pid).map { !$0.isTerminated } == true
        }
        if !cached.isEmpty { load(cached, focused: RecencyTracker.shared.order.first ?? 0) }
        log.notice("begin #\(id) appOnly=\(appOnly) cached=\(cached.count)")
        WindowScanner.scan(config: config, onlyPID: onlyPID) { [weak self] result in
            self?.scanned(result, session: id, full: onlyPID == nil)
        }

        startPolling()
        // Show after a beat: a quick ⌥⇥ tap switches without ever flashing the panel.
        let delay: TimeInterval = stayOpen ? 0 : 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, var session = self.session, session.id == id, !session.shown else { return }
            if session.loaded {
                self.reveal()
            } else {
                session.showDue = true
                self.session = session
            }
        }
    }

    private func scanned(_ result: WindowScanner.ScanResult, session id: Int, full: Bool) {
        let items = merged(result)
        if full { cache = items }
        guard let session, session.id == id else { return }
        log.notice("scan #\(id) in \(session.elapsedMS) ms: \(items.count) windows, \(result.late.count) apps late")
        if result.focused != 0 { RecencyTracker.shared.note(result.focused) }
        let before = model.items.map(\.id)
        load(items, focused: result.focused)
        guard let session = self.session else { return }
        if session.commitOnLoad {
            commit("release before scan")
        } else if session.showDue && !session.shown {
            reveal()
        } else if session.shown && model.items.map(\.id) != before {
            showPanel()
        }
    }

    /// Puts `items` in the model in recency order. Until the user moves the
    /// selection it starts on the previous window; after, it stays on theirs.
    private func load(_ items: [SwitchItem], focused: CGWindowID) {
        guard var session else { return }
        let ordered = SwitcherLogic.order(items, wid: \.wid, bucket: \.bucket, mru: RecencyTracker.shared.order)
        let keep = session.userMoved ? model.selectedItem?.id : nil
        model.items = ordered
        if let keep, let index = ordered.firstIndex(where: { $0.id == keep }) {
            model.selected = index
        } else {
            model.selected = SwitcherLogic.initialSelection(
                count: ordered.count, firstIsCurrent: focused != 0 && ordered.first?.wid == focused
            )
        }
        session.loaded = true
        self.session = session
    }

    private func reveal() {
        guard var session else { return }
        session.shown = true
        session.mouseAnchor = NSEvent.mouseLocation
        self.session = session
        showPanel()
        log.notice("shown #\(session.id) after \(session.elapsedMS) ms")
    }

    private func commit(_ reason: String) {
        guard var session else { return }
        guard session.loaded else {
            // Released before any window list arrived: finish when the scan lands.
            session.commitOnLoad = true
            self.session = session
            pollTimer?.invalidate()
            pollTimer = nil
            return
        }
        let target = model.selectedItem
        log.notice("commit #\(session.id) (\(reason, privacy: .public)) after \(session.elapsedMS) ms, shown=\(session.shown): \(target?.appName ?? "nothing", privacy: .public) at \(self.model.selected)")
        end()
        guard let target else { return }
        WindowScanner.focus(target, cursorFollows: config.cursorFollowsFocus)
        RecencyTracker.shared.note(target.wid)
    }

    private func cancel() {
        end()
    }

    private func end() {
        session = nil
        pollTimer?.invalidate()
        pollTimer = nil
        if !swallowMouseUp { setTaps(enabled: false) }
        panel?.orderOut(nil)
        model.hovered = nil
        SwitcherTrigger.shared.setActive(false)
        registerHotKeys()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.03, repeats: true) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { SwitcherController.shared.pollModifiers() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Safety net for the release: the hardware state is the truth.
    private func pollModifiers() {
        guard let session, !session.stayOpen else { return }
        if !NSEvent.modifierFlags.contains(config.modifier.flags) { commit("release (poll)") }
    }

    private func move(by delta: Int, isRepeat: Bool) {
        let next = SwitcherLogic.step(model.selected, count: model.items.count, by: delta, isRepeat: isRepeat)
        select(next)
    }

    private func moveRow(by delta: Int, isRepeat: Bool) {
        let columns = model.style == .titles ? 1 : model.columns
        select(SwitcherLogic.rowMove(model.selected, count: model.items.count, columns: columns, by: delta, isRepeat: isRepeat))
    }

    private func select(_ index: Int) {
        guard index != model.selected, model.items.indices.contains(index) else { return }
        model.selectedByPointer = false
        model.selected = index
        model.hovered = nil
        session?.userMoved = true
        // Keyboard moves re-arm the hover dead zone so a resting pointer can't steal it back.
        session?.mouseAnchor = NSEvent.mouseLocation
        session?.hoverArmed = false
    }

    /// Acts on the selected window, then refreshes the list in place.
    private func act(_ action: (SwitchItem) -> Void, settle: TimeInterval) {
        guard let item = model.selectedItem else { return }
        action(item)
        let keepID = item.id
        let keepIndex = model.selected
        guard let id = session?.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, let session = self.session, session.id == id else { return }
            let onlyPID = session.appOnly ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
            WindowScanner.scan(config: self.config, onlyPID: onlyPID) { [weak self] result in
                guard let self, let session = self.session, session.id == id else { return }
                let items = SwitcherLogic.order(result.items, wid: \.wid, bucket: \.bucket, mru: RecencyTracker.shared.order)
                self.model.items = items
                self.model.selected = items.firstIndex { $0.id == keepID } ?? min(keepIndex, max(items.count - 1, 0))
                if session.shown { self.showPanel() }
            }
        }
    }

    // MARK: Panel

    private func showPanel() {
        let panel = self.panel ?? makePanel()
        guard let hosting, let screen = targetScreen() else { return }
        layout(for: screen)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let visible = screen.visibleFrame
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded())
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        requestPreviews()
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel()
        let hosting = NSHostingView(rootView: SwitcherView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    /// Sizes the grid for `screen`: card size steps down to fit three rows,
    /// and anything beyond the screen's height scrolls.
    private func layout(for screen: NSScreen) {
        let visible = screen.visibleFrame
        let maxWidth = visible.width * 0.85 - SwitcherMetrics.padding * 2
        let hints = config.showKeyHints ? SwitcherMetrics.hintsHeight : 0
        let maxHeight = visible.height * 0.8 - SwitcherMetrics.padding * 2 - hints
        let count = model.items.count
        let spacing = SwitcherMetrics.spacing
        var contentHeight: CGFloat
        switch config.style {
        case .thumbnails:
            let size = SwitcherLogic.fittingSize(count: count, preferred: config.size, maxRows: 3, maxWidth: maxWidth,
                                                 spacing: spacing, width: SwitcherMetrics.cardWidth)
            model.size = size
            model.columns = SwitcherLogic.columns(count: count, cardWidth: SwitcherMetrics.cardWidth(size),
                                                  spacing: spacing, maxWidth: maxWidth)
            let rows = CGFloat((count + model.columns - 1) / max(model.columns, 1))
            contentHeight = rows * SwitcherMetrics.cardHeight(size) + max(rows - 1, 0) * spacing
        case .icons:
            model.columns = SwitcherLogic.columns(count: count, cardWidth: SwitcherMetrics.iconCell,
                                                  spacing: spacing, maxWidth: min(maxWidth, 900))
            let rows = CGFloat((count + model.columns - 1) / max(model.columns, 1))
            contentHeight = rows * SwitcherMetrics.iconCell + max(rows - 1, 0) * spacing
            contentHeight += SwitcherMetrics.iconTitleHeight
        case .titles:
            model.columns = 1
            contentHeight = CGFloat(count) * (SwitcherMetrics.listRow + 2)
        }
        let limit = config.style == .titles ? min(maxHeight, 12 * (SwitcherMetrics.listRow + 2)) : maxHeight
        model.scrollHeight = contentHeight > limit ? limit : nil
    }

    private func targetScreen() -> NSScreen? {
        switch config.screen {
        case .mouse:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        case .main:
            return NSScreen.screens.first
        case .active:
            guard let primary = NSScreen.screens.first,
                let frame = model.items.first(where: { !$0.isWindowless && $0.frame.width > 0 })?.frame
            else { return NSScreen.main }
            let center = NSPoint(x: frame.midX, y: primary.frame.maxY - frame.midY)
            return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) } ?? NSScreen.main
        }
    }

    private func requestPreviews() {
        guard model.previewsOn else { return }
        let wids = model.items.filter { !$0.isWindowless && $0.wid != 0 }.map(\.wid)
        PreviewStore.shared.forget(except: Set(wids))
        let pixels = SwitcherMetrics.cardWidth(model.size) * 2
        PreviewStore.shared.capture(wids, pixelWidth: pixels) { [weak self] wid, image in
            self?.model.images[wid] = image
        }
    }

    // MARK: Event tap

    private func setTaps(enabled: Bool) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: enabled) }
        if let moveTap { CGEvent.tapEnable(tap: moveTap, enable: enabled) }
    }

    private func createTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        if moveTap == nil {
            let moves = (CGEventMask(1) << CGEventType.mouseMoved.rawValue)
                | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
            if let moveTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: moves,
                callback: { _, type, event, _ in
                    MainActor.assumeIsolated { SwitcherController.shared.handleMove(type) }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: nil
            ) {
                let source = CFMachPortCreateRunLoopSource(nil, moveTap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                CGEvent.tapEnable(tap: moveTap, enable: false)
                self.moveTap = moveTap
            }
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                let swallow = MainActor.assumeIsolated { SwitcherController.shared.handle(type, event) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = tap
    }

    private func handleMove(_ type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let moveTap, session != nil { CGEvent.tapEnable(tap: moveTap, enable: true) }
            return
        }
        handleHover()
    }

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, session != nil || swallowMouseUp { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if session == nil, swallowMouseUp {
            guard type == .leftMouseUp else { return false }
            finishClick()
            return true
        }
        guard var session else { return false }
        switch type {
        case .flagsChanged:
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            if !session.stayOpen && !flags.contains(config.modifier.flags) {
                DispatchQueue.main.async { MainActor.assumeIsolated { SwitcherController.shared.commit("release") } }
                return false
            }
            let shift = flags.contains(.shift)
            if shift && !session.shiftDown { move(by: -1, isRepeat: false) }
            session.shiftDown = shift
            self.session = session
            return false
        case .keyDown:
            handleKey(event)
            return true
        case .keyUp:
            return true
        case .leftMouseDown:
            guard session.shown, let panel else { return false }
            if let index = cardUnderPointer() {
                // Show the press right away; open on release, like a button.
                model.selectedByPointer = true
                model.selected = index
                model.hovered = nil
                session.pressedIndex = index
                session.swallowedMouseDown = true
                session.userMoved = true
                self.session = session
                swallowMouseUp = true
                return true
            }
            if panel.frame.contains(NSEvent.mouseLocation) {
                session.swallowedMouseDown = true
                self.session = session
                return true
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { SwitcherController.shared.cancel() } }
            return false
        case .leftMouseUp:
            if let pressed = session.pressedIndex {
                session.pressedIndex = nil
                self.session = session
                // Released off the card it was pressed on: treat as a cancelled click.
                if cardUnderPointer() == pressed {
                    DispatchQueue.main.async { MainActor.assumeIsolated { SwitcherController.shared.commit("click") } }
                }
                finishClick()
                return true
            }
            return session.swallowedMouseDown
        default:
            return false
        }
    }

    private func handleKey(_ event: CGEvent) {
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let shift = event.flags.contains(.maskShift)
        switch Int(code) {
        case kVK_Tab: move(by: shift ? -1 : 1, isRepeat: isRepeat)
        case kVK_ANSI_Grave: move(by: shift ? -1 : 1, isRepeat: isRepeat)
        case kVK_RightArrow: move(by: 1, isRepeat: isRepeat)
        case kVK_LeftArrow: move(by: -1, isRepeat: isRepeat)
        case kVK_DownArrow: moveRow(by: 1, isRepeat: isRepeat)
        case kVK_UpArrow: moveRow(by: -1, isRepeat: isRepeat)
        case kVK_Escape: cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: commit("return")
        case kVK_ANSI_W where !isRepeat: act(WindowScanner.close, settle: 0.3)
        case kVK_ANSI_M where !isRepeat: act(WindowScanner.toggleMinimize, settle: 0.4)
        case kVK_ANSI_H where !isRepeat: act({ WindowScanner.toggleHide($0) }, settle: 0.3)
        case kVK_ANSI_Q where !isRepeat: act({ WindowScanner.quit($0) }, settle: 0.6)
        default: break
        }
    }

    /// The click's mouse-up has been eaten; let the taps go if the session is over.
    private func finishClick() {
        swallowMouseUp = false
        if session == nil { setTaps(enabled: false) }
    }

    private func handleHover() {
        guard var session, session.shown, session.pressedIndex == nil else { return }
        let mouse = NSEvent.mouseLocation
        if !session.hoverArmed {
            // A small dead zone after opening or a key press, so a hand
            // brushing the trackpad while typing doesn't steal the selection.
            let moved = hypot(mouse.x - session.mouseAnchor.x, mouse.y - session.mouseAnchor.y)
            guard moved > 6 else { return }
            session.hoverArmed = true
            self.session = session
        }
        let index = cardUnderPointer()
        if config.hoverSelects {
            if let index, index != model.selected {
                model.selectedByPointer = true
                model.selected = index
                session.userMoved = true
                self.session = session
            }
            if model.hovered != nil { model.hovered = nil }
        } else if model.hovered != index {
            model.hovered = index
        }
    }

    private func cardUnderPointer() -> Int? {
        panelPoint().flatMap { model.index(at: $0) }
    }

    /// The pointer in the hosting view's top-left coordinates.
    private func panelPoint() -> CGPoint? {
        guard let panel, panel.isVisible else { return nil }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        guard frame.contains(mouse) else { return nil }
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }
}
