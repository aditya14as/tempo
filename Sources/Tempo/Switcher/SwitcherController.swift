import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

/// The ⌥⇥ switcher's brain.
///
/// Trigger: a Carbon hot key for hold+⇥ (and hold+` for "this app's windows"),
/// which swallows the combo system-wide. Once a session is open, the Carbon
/// keys are released and an event tap takes over: it swallows every key the
/// switcher uses, watches for the hold key's release, and handles the mouse.
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
    private var session: Session?
    private var pollTimer: Timer?
    private var permissionTimer: Timer?
    private var configObservation: AnyCancellable?
    private var disabledSymbolicKeys: [Int32] = []

    private struct Session {
        var appOnly: Bool
        /// Opened from the menu: stays up until a click, ↩ or ⎋.
        var stayOpen: Bool
        var shown = false
        var shiftDown = false
        var mouseAnchor: CGPoint
        var hoverArmed = false
        var swallowedMouseDown = false
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
        if trusted != accessibilityGranted { accessibilityGranted = trusted }
        guard trusted else { return }
        RecencyTracker.shared.start()
        if tap == nil { createTap() }
    }

    private func apply(_ config: SwitcherConfig) {
        let old = self.config
        self.config = config
        if session != nil, old.modifier != config.modifier || !config.enabled { cancel() }
        registerHotKeys()
        model.theme = store?.config.theme ?? .aurora
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
            MainActor.assumeIsolated { SwitcherController.shared.hotKeyPressed(appOnly: appOnly) }
            return noErr
        }, 1, &spec, nil, &carbonHandler)
    }

    private func registerHotKeys() {
        unregisterHotKeys()
        restoreSystemShortcuts()
        guard config.enabled, session == nil else { return }
        let mods: UInt32
        switch config.modifier {
        case .option: mods = UInt32(optionKey)
        case .control: mods = UInt32(controlKey)
        case .command: mods = UInt32(cmdKey)
        }
        if config.modifier == .command {
            // Take ⌘⇥ (and ⌘` when used) away from the system while Tempo owns it.
            var ids: [Int32] = [1, 2]
            if config.appWindowsKey { ids.append(27) }
            for id in ids where PrivateAPIs.setSymbolicHotKey(id, enabled: false) { disabledSymbolicKeys.append(id) }
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

    private func hotKeyPressed(appOnly: Bool) {
        if session != nil {
            move(by: 1, isRepeat: false)
            return
        }
        guard accessibilityGranted else {
            Permissions.requestAccessibility()
            return
        }
        begin(appOnly: appOnly, stayOpen: false)
    }

    // MARK: Session

    private func begin(appOnly: Bool, stayOpen: Bool) {
        guard session == nil, let store else { return }
        if tap == nil { createTap() }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        unregisterHotKeys()
        session = Session(appOnly: appOnly, stayOpen: stayOpen, mouseAnchor: NSEvent.mouseLocation)

        let front = NSWorkspace.shared.frontmostApplication
        let onlyPID = appOnly ? front?.processIdentifier : nil
        let current = WindowScanner.focusedWindowID()
        if current != 0 { RecencyTracker.shared.note(current) }
        let scanned = WindowScanner.scan(config: config, onlyPID: onlyPID)
        let items = SwitcherLogic.order(scanned, wid: \.wid, bucket: \.bucket, mru: RecencyTracker.shared.order)

        model.theme = store.config.theme
        model.style = config.style
        model.showHints = config.showKeyHints
        model.showSpaceBadges = config.showSpaceBadges
        model.previewsOn = config.previews && config.style == .thumbnails && PreviewStore.shared.available
        model.hovered = nil
        model.images = PreviewStore.shared.cache
        model.items = items
        model.selected = SwitcherLogic.initialSelection(
            count: items.count, firstIsCurrent: current != 0 && items.first?.wid == current
        )

        startPolling()
        // Show after a beat: a quick ⌥⇥ tap switches without ever flashing the panel.
        let delay: TimeInterval = stayOpen ? 0 : 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, var session = self.session, !session.shown else { return }
            session.shown = true
            session.mouseAnchor = NSEvent.mouseLocation
            self.session = session
            self.showPanel()
        }
    }

    private func commit() {
        guard session != nil else { return }
        let target = model.selectedItem
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
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        panel?.orderOut(nil)
        model.hovered = nil
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
        if !NSEvent.modifierFlags.contains(config.modifier.flags) { commit() }
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
        model.selected = index
        model.hovered = nil
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
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self, let session = self.session else { return }
            let onlyPID = session.appOnly ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
            let scanned = WindowScanner.scan(config: self.config, onlyPID: onlyPID)
            let items = SwitcherLogic.order(scanned, wid: \.wid, bucket: \.bucket, mru: RecencyTracker.shared.order)
            self.model.items = items
            self.model.selected = items.firstIndex { $0.id == keepID } ?? min(keepIndex, max(items.count - 1, 0))
            if session.shown { self.showPanel() }
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

    private func createTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp,
                                    .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
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

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, session != nil { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard var session else { return false }
        switch type {
        case .flagsChanged:
            let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            if !session.stayOpen && !flags.contains(config.modifier.flags) {
                DispatchQueue.main.async { MainActor.assumeIsolated { SwitcherController.shared.commit() } }
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
        case .mouseMoved, .leftMouseDragged:
            handleHover()
            return false
        case .leftMouseDown:
            guard session.shown, let panel else { return false }
            if let point = panelPoint(), let index = model.index(at: point) {
                model.selected = index
                session.swallowedMouseDown = true
                self.session = session
                DispatchQueue.main.async { MainActor.assumeIsolated { SwitcherController.shared.commit() } }
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
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space: commit()
        case kVK_ANSI_W where !isRepeat: act(WindowScanner.close, settle: 0.3)
        case kVK_ANSI_M where !isRepeat: act(WindowScanner.toggleMinimize, settle: 0.4)
        case kVK_ANSI_H where !isRepeat: act({ WindowScanner.toggleHide($0) }, settle: 0.3)
        case kVK_ANSI_Q where !isRepeat: act({ WindowScanner.quit($0) }, settle: 0.6)
        default: break
        }
    }

    private func handleHover() {
        guard var session, session.shown else { return }
        let mouse = NSEvent.mouseLocation
        if !session.hoverArmed {
            let moved = hypot(mouse.x - session.mouseAnchor.x, mouse.y - session.mouseAnchor.y)
            guard moved > 20 else { return }
            session.hoverArmed = true
            self.session = session
        }
        let index = panelPoint().flatMap { model.index(at: $0) }
        if config.hoverSelects, let index {
            if index != model.selected { model.selected = index }
            if model.hovered != nil { model.hovered = nil }
        } else if model.hovered != index {
            model.hovered = index
        }
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
