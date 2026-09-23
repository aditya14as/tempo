import AppKit
import Combine
import SwiftUI

// MARK: - Clipboard popup controller

/// Sizes shared by the controller (window frame) and the popup view.
enum ClipboardMetrics {
    /// List plus preview pane, like Maccy. Shrunk to fit small screens.
    static let fullSize = NSSize(width: 760, height: 560)
    /// The panel's width with the preview pane hidden: just the list.
    static let listOnlyWidth: CGFloat = 420
    /// The list's share of the width when the preview pane is shown.
    static let listFraction: CGFloat = 0.55
    static let cornerRadius: CGFloat = 18
    static let rowHeight: CGFloat = 30
    /// The search bar and the preview's toolbar, side by side.
    static let topBarHeight: CGFloat = 46
    /// Tallest thumbnail in an image row.
    static let thumbnailHeight: CGFloat = 64
    static let thumbnailWidth: CGFloat = 150
    /// How far PageUp / PageDown jump.
    static let page = 10
    /// UserDefaults key: is the preview pane shown (default yes)?
    static let previewPaneKey = "tempo.clipboard.previewPane"
}

/// Runs the ⇧⌘C history popup the way Maccy does: a key panel that never
/// activates Tempo. Tempo is an `.accessory` app, so the app you were typing
/// in stays frontmost the whole time, and the ⌘V posted after picking an
/// entry lands right back in it.
@MainActor
final class ClipboardController: ObservableObject {
    static let shared = ClipboardController()

    /// What's typed in the popup's search field.
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            confirmingClear = false
            refresh(resetSelection: true)
        }
    }
    /// The popup's list: `ClipboardHistory.visible(query:)`, cached so key
    /// handling and drawing agree on the same rows.
    @Published private(set) var results: [ClipItem] = []
    @Published var selectedID: UUID?
    /// ⌥⌘⌫ asks first, inline — an alert would steal focus from the panel.
    @Published var confirmingClear = false
    @Published private(set) var isShown = false
    /// "⌘1"…"⌘9" and "⌘B"… for each row that has a shortcut.
    @Published private(set) var hints: [UUID: String] = [:]
    /// The selection moved by keyboard, so the list should scroll to it.
    /// Pointer selections never scroll (the row is already under the mouse).
    private(set) var selectedByKeyboard = true
    /// The preview pane right of the list; toggled from the search bar and
    /// remembered across launches.
    @Published private(set) var previewPaneShown =
        UserDefaults.standard.object(forKey: ClipboardMetrics.previewPaneKey) as? Bool ?? true
    /// The panel's current size: `desiredSize` fitted to the screen.
    @Published private(set) var panelSize = ClipboardMetrics.fullSize

    private weak var store: ConfigStore?
    private var panel: ClipboardPanel?
    /// The popup's search field, registered by the view so show() can focus it.
    weak var searchField: NSTextField?
    private var hotkeyToken: UInt32?
    private var boundShortcut: KeyCombo?
    private var shortcutBound = false
    private var configObservation: AnyCancellable?
    private var itemsObservation: AnyCancellable?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    /// Where the pointer was at the last keyboard move. Scrolling the list
    /// under a still pointer fires hover events; only real movement selects.
    private var pointerAtKeyMove: NSPoint?
    /// nil = looked up and not installed, so rows don't ask LaunchServices on every redraw.
    private var icons: [String: NSImage?] = [:]
    /// The last app other than Tempo to be frontmost. See `returnFocus`.
    private var previousApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    /// Read from disk once per showing, not on every redraw.
    private var previews: [UUID: String] = [:]
    private var files: [UUID: [URL]] = [:]

    var config: ClipboardConfig { store?.config.clipboard ?? ClipboardConfig() }
    var theme: Theme { store?.config.theme ?? .aurora }
    var selected: ClipItem? { results.first { $0.id == selectedID } }

    /// The list column's width inside `panelSize`.
    var listWidth: CGFloat {
        previewPaneShown ? (panelSize.width * ClipboardMetrics.listFraction).rounded() : panelSize.width
    }

    /// The size the panel wants before fitting it to a screen.
    private var desiredSize: NSSize {
        previewPaneShown ? ClipboardMetrics.fullSize
            : NSSize(width: ClipboardMetrics.listOnlyWidth, height: ClipboardMetrics.fullSize.height)
    }

    private func fitted(to visible: NSRect) -> NSSize {
        NSSize(width: min(desiredSize.width, visible.width - 8), height: min(desiredSize.height, visible.height - 8))
    }

    // MARK: - Lifecycle

    func start(store: ConfigStore) {
        guard self.store == nil else { return }
        self.store = store
        ClipboardHistory.shared.start(store: store)
        // @Published fires before the value changes; hop a turn so we read the new one.
        configObservation = store.$config
            .map(\.clipboard)
            .removeDuplicates()
            .sink { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { ClipboardController.shared.apply() } }
            }
        itemsObservation = ClipboardHistory.shared.$items
            .sink { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { ClipboardController.shared.itemsChanged() } }
            }
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, app != NSRunningApplication.current else { return }
                ClipboardController.shared.previousApp = app
            }
        }
        apply()
    }

    private func apply() {
        let config = config
        rebindShortcut(config.enabled ? config.shortcut : nil)
        if !config.enabled {
            hide()
        } else if isShown {
            refresh(resetSelection: false)
        }
    }

    private func rebindShortcut(_ combo: KeyCombo?) {
        guard !shortcutBound || combo != boundShortcut else { return }
        shortcutBound = true
        boundShortcut = combo
        HotkeyCenter.shared.rebind(&hotkeyToken, to: combo) {
            MainActor.assumeIsolated { ClipboardController.shared.toggle() }
        }
    }

    private func itemsChanged() {
        guard isShown else { return }
        refresh(resetSelection: false)
    }

    /// Re-reads the list; keeps the selected entry if it's still there.
    private func refresh(resetSelection: Bool) {
        results = ClipboardHistory.shared.visible(query: query)
        var hints: [UUID: String] = [:]
        var number = 0
        for item in results {
            if let pin = item.pin {
                hints[item.id] = "⌘" + pin.uppercased()
            } else if number < 9 {
                number += 1
                hints[item.id] = "⌘\(number)"
            }
        }
        if hints != self.hints { self.hints = hints }
        if resetSelection || !results.contains(where: { $0.id == selectedID }) {
            selectedByKeyboard = true
            selectedID = results.first?.id
        }
    }

    // MARK: - Show / hide

    func toggle() {
        isShown ? dismiss() : show()
    }

    func show() {
        guard let store, config.enabled else { return }
        // The switcher's event tap eats every key while it's up, so the popup
        // would sit there deaf; let the switcher finish first.
        guard !NSApp.windows.contains(where: { $0 is SwitcherPanel && $0.isVisible }) else { return }
        let panel = self.panel ?? makePanel(store)
        confirmingClear = false
        if query.isEmpty { refresh(resetSelection: true) } else { query = "" }
        previews.removeAll()
        files.removeAll()
        pointerAtKeyMove = NSEvent.mouseLocation
        position(panel)
        isShown = true
        // Never NSApp.activate: the app you came from must stay frontmost.
        panel.orderFrontRegardless()
        panel.makeKey()
        focusSearch()
        installMonitors()
        panel.invalidateShadow()
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        removeMonitors()
        panel?.orderOut(nil)
        confirmingClear = false
        previews.removeAll()
        files.removeAll()
    }

    /// Closing on purpose (⎋, ⌘W, the shortcut, picking an entry): like
    /// `hide`, then hands the keyboard back to the app you came from. Not for
    /// resignKey — there another Tempo window may be about to take key.
    func dismiss(then action: @escaping () -> Void = {}) {
        hide()
        returnFocus(then: action)
    }

    /// Normally Tempo was never active, so the app you were in still is and
    /// gets its key window back by itself. But opened from Tempo's own menu
    /// bar panel (the Clips tab button, or ⇧⌘C while it's open), Tempo IS the
    /// active app, and that panel closes when the popup takes key — the ⌘V
    /// would land in Tempo with no window to take it. Then reactivate the
    /// previous app and wait until it's in front before acting.
    private func returnFocus(then action: @escaping () -> Void) {
        guard NSApp.isActive, NSApp.keyWindow == nil, let app = previousApp, !app.isTerminated else {
            action()
            return
        }
        app.activate()
        waitUntilFrontmost(app, tries: 25, then: action)
    }

    private func waitUntilFrontmost(_ app: NSRunningApplication, tries: Int, then action: @escaping () -> Void) {
        if tries == 0 || NSWorkspace.shared.frontmostApplication == app {
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            MainActor.assumeIsolated {
                ClipboardController.shared.waitUntilFrontmost(app, tries: tries - 1, then: action)
            }
        }
    }

    private func makePanel(_ store: ConfigStore) -> ClipboardPanel {
        let panel = ClipboardPanel(size: panelSize)
        let host = NSHostingView(rootView: ClipboardPopupView(controller: self).environmentObject(store))
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.onResignKey = { MainActor.assumeIsolated { ClipboardController.shared.hide() } }
        host.layoutSubtreeIfNeeded()
        self.panel = panel
        return panel
    }

    private func focusSearch() {
        guard let panel else { return }
        if let field = searchField {
            panel.makeFirstResponder(field)
        } else {
            // First show: SwiftUI builds the field a beat later.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let controller = ClipboardController.shared
                    if controller.isShown, let field = controller.searchField { controller.panel?.makeFirstResponder(field) }
                }
            }
        }
    }

    /// Places the panel per `config.position` on the screen under the pointer.
    private func position(_ panel: ClipboardPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = fitted(to: visible)
        panelSize = size
        var origin: NSPoint
        switch config.position {
        case .cursor:
            // Below-right of the pointer; flip to the other side when it won't fit.
            origin = NSPoint(x: mouse.x + 2, y: mouse.y - size.height - 2)
            if origin.x + size.width > visible.maxX { origin.x = mouse.x - size.width - 2 }
            if origin.y < visible.minY { origin.y = mouse.y + 2 }
        case .center:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2 + visible.height * 0.08)
        case .menuBar:
            origin = NSPoint(x: visible.maxX - size.width - 10, y: visible.maxY - size.height - 6)
        }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        panel.place(NSRect(origin: origin, size: size))
    }

    /// Shows or hides the preview pane. While the popup is up it resizes in
    /// place, keeping its top-left corner (moved left only if it'd go off screen).
    func togglePreviewPane() {
        previewPaneShown.toggle()
        UserDefaults.standard.set(previewPaneShown, forKey: ClipboardMetrics.previewPaneKey)
        guard isShown, let panel, let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else {
            panelSize = desiredSize
            return
        }
        let size = fitted(to: visible)
        let top = panel.frame.maxY
        var origin = NSPoint(x: panel.frame.minX, y: top - size.height)
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        panelSize = size
        panel.place(NSRect(origin: origin, size: size))
        panel.invalidateShadow()
    }

    // MARK: - Committing

    /// Picks an entry: hides the popup, then pastes into the front app or
    /// just copies. ⌥ swaps paste/copy, ⇧ swaps plain/formatted.
    func select(_ item: ClipItem, alternate: Bool = false, shift: Bool = false) {
        let config = config
        let plain = config.plainTextPaste != shift
        if config.pasteOnSelect != alternate {
            paste(item, plain: plain)
        } else {
            copy(item, plain: plain)
        }
    }

    /// Always pastes (context menu "Paste"). paste() waits a moment before
    /// ⌘V, so the previous app's window has taken key back by then.
    func paste(_ item: ClipItem, plain: Bool) {
        dismiss { ClipboardHistory.shared.paste(item, plain: plain) }
    }

    func copy(_ item: ClipItem, plain: Bool) {
        dismiss { ClipboardHistory.shared.copy(item, plain: plain) }
    }

    /// A click on a row; modifier keys work like they do with ↩.
    func click(_ item: ClipItem) {
        let flags = NSEvent.modifierFlags
        select(item, alternate: flags.contains(.option), shift: flags.contains(.shift))
    }

    func commitSelected(alternate: Bool, shift: Bool) {
        if let item = selected {
            select(item, alternate: alternate, shift: shift)
        } else if results.isEmpty, !query.isEmpty {
            // Nothing matches: ↩ copies what you typed.
            let text = query
            dismiss { ClipboardHistory.shared.copyText(text) }
        }
    }

    func togglePinSelected() {
        guard let id = selectedID else { return }
        ClipboardHistory.shared.togglePin(id)
    }

    func deleteSelected() {
        guard let id = selectedID, let index = results.firstIndex(where: { $0.id == id }) else { return }
        // Keep the selection in place: the next row moves up into it.
        let next = results.indices.contains(index + 1) ? results[index + 1].id
            : index > 0 ? results[index - 1].id : nil
        selectedByKeyboard = true
        selectedID = next
        ClipboardHistory.shared.delete(id)
    }

    var unpinnedCount: Int { ClipboardHistory.shared.items.filter { !$0.isPinned }.count }

    func clearUnpinned() {
        confirmingClear = false
        ClipboardHistory.shared.clear(keepPinned: true)
    }

    func togglePaused() {
        store?.config.clipboard.paused.toggle()
    }

    /// The text Vision read out of an image entry, if any.
    static func imageText(_ item: ClipItem) -> String? {
        guard item.kind == .image, let text = item.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }

    /// "Copy text" on an image: copies what was read out of it.
    func copyImageText(_ item: ClipItem) {
        guard let text = Self.imageText(item) else { return }
        dismiss { ClipboardHistory.shared.copyText(text) }
    }

    /// Tempo's settings live in its menu bar dropdown: close the popup, then
    /// open the dropdown on its Settings page as if its icon was clicked.
    func openSettings() {
        PanelRequest.openSettings()
        dismiss {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                MainActor.assumeIsolated { ClipboardController.statusButton()?.performClick(nil) }
            }
        }
    }

    private static func statusButton() -> NSStatusBarButton? {
        func find(_ view: NSView?) -> NSStatusBarButton? {
            guard let view else { return nil }
            if let button = view as? NSStatusBarButton { return button }
            for sub in view.subviews {
                if let button = find(sub) { return button }
            }
            return nil
        }
        for window in NSApp.windows where window.className.contains("StatusBarWindow") {
            if let button = find(window.contentView) { return button }
        }
        return nil
    }

    // MARK: - Selection

    func hoverSelect(_ id: UUID) {
        let mouse = NSEvent.mouseLocation
        if let last = pointerAtKeyMove, last == mouse { return }
        pointerAtKeyMove = nil
        guard selectedID != id else { return }
        selectedByKeyboard = false
        selectedID = id
    }

    private func move(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? -1
        moveTo(min(max(current + delta, 0), results.count - 1))
    }

    private func moveTo(_ index: Int) {
        guard results.indices.contains(index) else { return }
        pointerAtKeyMove = NSEvent.mouseLocation
        selectedByKeyboard = true
        selectedID = results[index].id
    }

    // MARK: - Keys

    private func installMonitors() {
        removeMonitors()
        // Local monitors run on the main thread, before the panel sees the key.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        // Belt and braces for resignKey: a click in any other app closes the popup.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { ClipboardController.shared.hide() } }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    private static let digitKeys: [UInt16: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    /// Handles a key pressed while the popup is key. Returns false to let it
    /// through to the search field (plain typing, ⌫, ←/→ …).
    private func handle(_ event: NSEvent) -> Bool {
        guard isShown, let panel, event.window === panel else { return false }
        // Composing with an input method: every key belongs to the IME.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let cmd = flags.contains(.command), opt = flags.contains(.option)
        let ctrl = flags.contains(.control), shift = flags.contains(.shift)
        let char = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // A click in the preview's text moved the keyboard there; typing
        // (and ⌫, ←/→) belongs to the search field, so take it back first.
        if !cmd && !ctrl, let field = searchField, !isEditing(field, in: panel) {
            panel.makeFirstResponder(field)
            if let editor = field.currentEditor() as? NSTextView {
                editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
            }
        }

        if confirmingClear {
            switch event.keyCode {
            case 36, 76:
                clearUnpinned()
                return true
            case 53:
                confirmingClear = false
                return true
            default:
                confirmingClear = false  // any other key: never mind, and handle it normally
            }
        }

        switch event.keyCode {
        case 53:  // ⎋
            if !query.isEmpty { query = "" } else { dismiss() }
            return true
        case 36, 76:  // ↩ ⌤
            commitSelected(alternate: opt, shift: shift)
            return true
        case 126:  // ↑
            cmd ? moveTo(0) : move(by: -1)
            return true
        case 125:  // ↓
            cmd ? moveTo(results.count - 1) : move(by: 1)
            return true
        case 116:  // PageUp
            move(by: -ClipboardMetrics.page)
            return true
        case 121:  // PageDown
            move(by: ClipboardMetrics.page)
            return true
        case 115:  // Home
            moveTo(0)
            return true
        case 119:  // End
            moveTo(results.count - 1)
            return true
        case 51, 117:  // ⌫ ⌦
            if opt && cmd {
                if unpinnedCount > 0 { confirmingClear = true }
                return true
            }
            if opt {
                deleteSelected()
                return true
            }
            return false
        default:
            break
        }

        if ctrl && !cmd && !opt {
            switch char {
            case "p", "k": move(by: -1); return true
            case "n", "j": move(by: 1); return true
            case "u": query = ""; return true
            default: break
            }
        }
        if opt && !cmd && !ctrl && (char == "p" || event.keyCode == 35) {
            togglePinSelected()
            return true
        }
        if opt && !cmd && !ctrl && event.keyCode == 17 {  // ⌥T: copy the text in an image
            if let item = selected, Self.imageText(item) != nil { copyImageText(item) }
            return true
        }
        if cmd && !ctrl && !opt && event.keyCode == 43 {  // ⌘,
            openSettings()
            return true
        }
        if cmd && !ctrl {
            if let number = Self.digitKeys[event.keyCode] {
                let unpinned = results.filter { !$0.isPinned }
                if unpinned.count >= number { select(unpinned[number - 1], alternate: opt, shift: shift) }
                return true
            }
            if let item = results.first(where: { $0.pin != nil && $0.pin?.lowercased() == char }) {
                select(item, alternate: opt, shift: shift)
                return true
            }
            // No Edit menu reaches a non-activating panel: route the usual
            // text shortcuts to the search field by hand.
            let action: Selector? = switch char {
            case "a": #selector(NSText.selectAll(_:))
            case "c": #selector(NSText.copy(_:))
            case "v": #selector(NSText.paste(_:))
            case "x": #selector(NSText.cut(_:))
            case "z": shift ? Selector(("redo:")) : Selector(("undo:"))
            default: nil
            }
            if let action {
                NSApp.sendAction(action, to: nil, from: panel)
                return true
            }
            if char == "w" {
                dismiss()
                return true
            }
            // Tempo's main menu still answers key equivalents for this key
            // window: without this ⌘Q would quit Tempo and ⌘H hide it. Arrow
            // and other function keys (⌘← …) still reach the search field.
            if let scalar = char.unicodeScalars.first, scalar.value < 0xF700 { return true }
        }
        return false
    }

    private func isEditing(_ field: NSTextField, in panel: NSPanel) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return panel.firstResponder === editor
    }

    // MARK: - Cached artwork

    func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            ? AppRef(bundleID: bundleID, name: bundleID).icon : nil
        icons[bundleID] = .some(icon)
        return icon
    }

    /// The engine decodes thumbnails off the main thread and caches them; it
    /// returns nil until one is ready, then nudges its observers to redraw.

    /// The entry's full text (the engine caps it at 20,000 characters).
    func previewText(_ item: ClipItem) -> String {
        if let cached = previews[item.id] { return cached }
        let text = ClipboardHistory.shared.previewText(item)
        previews[item.id] = text
        return text
    }

    func fileURLs(_ item: ClipItem) -> [URL] {
        if let cached = files[item.id] { return cached }
        let urls = ClipboardHistory.shared.fileURLs(item)
        files[item.id] = urls
        return urls
    }
}

// MARK: - Panel

/// The popup's window: a borderless HUD card that can take key (so you can
/// type into its search field) without ever activating Tempo. It floats at
/// menu level — above Chrome's autofill bubbles — on every Space, including
/// full-screen ones.
final class ClipboardPanel: NSPanel {
    /// Called when another window (or app) takes key: a click outside closes the popup.
    var onResignKey: (() -> Void)?

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var placing = false

    /// Only the controller moves the popup while it's up. PanelAligner adopts
    /// any key window hugging the menu bar as Tempo's dropdown and would drag
    /// the popup (opened "under the menu bar", or near the top at the
    /// pointer) beneath Tempo's icon at the dropdown's size.
    func place(_ frame: NSRect) {
        placing = true
        defer { placing = false }
        setFrame(frame, display: false)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard placing || !isVisible else { return }
        super.setFrame(frameRect, display: flag)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        guard placing || !isVisible else { return }
        super.setFrameOrigin(point)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// ⎋ is handled by the controller's key monitor; don't let AppKit beep.
    override func cancelOperation(_ sender: Any?) {}
}
