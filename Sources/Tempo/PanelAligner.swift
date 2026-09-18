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
        fit()
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
            && window.frame.height > 100
            && window.frame.maxY > top - 40
    }

    private func fit() {
        guard let window, let icon = StatusItemDropper.iconScreenFrame() else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let width = contentSize.width > 0 ? contentSize.width : window.frame.width
        let height = contentSize.height > 0 ? contentSize.height : window.frame.height
        // Centered under the icon, clamped on-screen.
        var x = icon.midX - width / 2
        x = max(visible.minX + 8, min(x, visible.maxX - width - 8))
        // Top edge just under the menu bar — the same spot SwiftUI hangs it.
        let top = visible.maxY - 2
        let frame = NSRect(x: x, y: top - height, width: width, height: height)
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
