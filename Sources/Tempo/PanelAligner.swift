import AppKit
import SwiftUI

/// Keeps the menu bar dropdown hugging the icon.
///
/// SwiftUI's `MenuBarExtra` (.window style) places its panel itself and then
/// leaves it alone: for an item that isn't hard against the right screen edge
/// the panel juts out to the RIGHT of the icon, and its height is fixed at
/// whatever the first-shown tab needed — switch to a shorter tab and the card
/// floats vertically centered in that too-tall window, leaving a see-through
/// gap under the menu bar. SwiftUI exposes no API for either, so PanelView
/// hands us its window and its laid-out size, and we keep the window's frame
/// fitted to that content: top edge under the menu bar, centered under the
/// icon.
@MainActor
final class PanelAligner {
    static let shared = PanelAligner()
    private weak var window: NSWindow?
    private var contentSize: CGSize = .zero
    private var observer: NSObjectProtocol?
    private var frameObservers: [NSObjectProtocol] = []
    private var fitting = false

    func start() {
        guard observer == nil else { return }
        // SwiftUI re-places the panel each time it shows it; refit just before
        // it becomes visible so the user never sees the un-aligned frame.
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                let aligner = PanelAligner.shared
                guard let window = note.object as? NSWindow else { return }
                if window === aligner.window {
                    aligner.fit()
                } else if aligner.looksLikeDropdown(window) {
                    // The tracker missed (or SwiftUI re-hosted the content):
                    // adopt the dropdown by shape so alignment never silently
                    // stops working.
                    aligner.attach(window)
                }
            }
        }
    }

    /// The dropdown's NSWindow, reported by the hosted PanelView.
    func attach(_ window: NSWindow) {
        guard window !== self.window else { return }
        self.window = window
        PanelVisibility.shared.track(window)
        // While the content's height animates (switching tabs), SwiftUI
        // resizes the window on every frame and each time snaps it back to its
        // own spot, right of the icon. Put it back in the same call, before
        // the frame is drawn, or the panel visibly jumps sideways.
        frameObservers.forEach(NotificationCenter.default.removeObserver)
        frameObservers = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: nil) { _ in
                MainActor.assumeIsolated { PanelAligner.shared.holdPlace() }
            }
        }
        fit()
    }

    /// Moves the window back under the icon, keeping whatever size it has now.
    private func holdPlace() {
        guard !fitting, let window, window.isVisible, let origin = origin(for: window.frame.size),
            origin != window.frame.origin
        else { return }
        fitting = true
        defer { fitting = false }
        window.setFrameOrigin(origin)
    }

    /// Where a panel of `size` belongs: centered under the icon, clamped
    /// on-screen, its top edge just under the menu bar.
    private func origin(for size: CGSize) -> NSPoint? {
        guard let icon = StatusItemDropper.iconScreenFrame() else { return nil }
        let screen = NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return nil }
        let x = max(visible.minX + 8, min(icon.midX - size.width / 2, visible.maxX - size.width - 8))
        // The same spot SwiftUI hangs it.
        return NSPoint(x: x, y: visible.maxY - 2 - size.height)
    }

    /// PanelView's laid-out size (its intrinsic height, not the window's).
    func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        fit()
    }

    /// Fallback identification: a tall, visible app window hugging the menu
    /// bar that isn't the status item, the Shelf card, or a small popover.
    private func looksLikeDropdown(_ window: NSWindow) -> Bool {
        guard let top = NSScreen.main?.visibleFrame.maxY else { return false }
        return window.isVisible
            && !window.className.contains("StatusBarWindow")
            && !ShelfWindow.shared.isShelf(window)
            && !(window is ClipboardPanel)
            && window.frame.height > 100
            && window.frame.maxY > top - 40
    }

    private func fit() {
        guard let window else { return }
        // Whole points: SwiftUI sizes the window in whole points, and a
        // fractional target would have the two fighting over half a point.
        let width = contentSize.width > 0 ? contentSize.width.rounded() : window.frame.width
        let height = contentSize.height > 0 ? contentSize.height.rounded() : window.frame.height
        guard let origin = origin(for: CGSize(width: width, height: height)) else { return }
        let frame = NSRect(origin: origin, size: CGSize(width: width, height: height))
        guard !frame.equalTo(window.frame), !fitting else { return }
        fitting = true
        defer { fitting = false }
        // Order matters: SwiftUI's MenuBarExtraWindow re-anchors the window
        // to its own spot whenever the SIZE changes, but leaves a plain origin
        // move alone. So set the size first, then place it.
        if window.frame.size != frame.size {
            window.setFrame(frame, display: false)
        }
        window.setFrameOrigin(frame.origin)
    }
}

/// Whether the menu bar dropdown is on screen, so its once-a-second clock
/// can stop while it's closed.
@MainActor
final class PanelVisibility: ObservableObject {
    static let shared = PanelVisibility()
    @Published private(set) var visible = true
    private var observers: [NSObjectProtocol] = []

    func track(_ window: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver)
        // Occlusion says when it's gone; becoming key (every open) is a
        // second, certain signal that it's back.
        observers = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    let visible = window.isKeyWindow || window.occlusionState.contains(.visible)
                    if PanelVisibility.shared.visible != visible { PanelVisibility.shared.visible = visible }
                }
            }
        }
    }
}

/// Invisible view that hands PanelView's hosting window to the aligner the
/// moment SwiftUI puts the view into it, and reports the content's size.
struct PanelWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> TrackerView { TrackerView() }
    func updateNSView(_ nsView: TrackerView, context: Context) {}

    final class TrackerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            MainActor.assumeIsolated {
                PanelAligner.shared.attach(window)
                PanelAligner.shared.contentSizeChanged(frame.size)
            }
        }

        /// SwiftUI lays this background view out to exactly the panel
        /// content's size, so its frame IS the content size. (A SwiftUI
        /// GeometryReader preference reports zero inside MenuBarExtra.)
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            MainActor.assumeIsolated { PanelAligner.shared.contentSizeChanged(newSize) }
        }
    }
}

