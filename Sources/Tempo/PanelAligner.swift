import AppKit

/// SwiftUI's `MenuBarExtra` (.window style) opens its dropdown at a position
/// macOS chooses — for an item that isn't hard against the right edge, that
/// leaves the panel jutting out to the RIGHT of the icon instead of hanging
/// beneath it like the Wi-Fi and battery menus. SwiftUI exposes no API to
/// control this, so the moment the panel becomes key we nudge it so its right
/// edge lines up under the icon's right edge. The panel is only positioned
/// once per open (SwiftUI doesn't keep re-placing it), so this holds.
@MainActor
final class PanelAligner {
    static let shared = PanelAligner()
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow {
                    PanelAligner.shared.alignIfDropdown(window)
                }
            }
        }
    }

    private func alignIfDropdown(_ window: NSWindow) {
        guard isMenuBarDropdown(window), let icon = StatusItemDropper.iconScreenFrame() else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(icon) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let width = window.frame.width
        // Right edge under the icon's right edge, clamped on-screen.
        var x = icon.maxX - width
        x = max(visible.minX + 8, min(x, visible.maxX - width - 8))
        if abs(window.frame.minX - x) > 1 {
            window.setFrameOrigin(NSPoint(x: x, y: window.frame.minY))
        }
    }

    /// The MenuBarExtra dropdown: a tall, visible app window hugging the menu
    /// bar that is neither the status item window nor the Shelf card nor a
    /// small popover (the due-date picker).
    private func isMenuBarDropdown(_ window: NSWindow) -> Bool {
        guard let top = NSScreen.main?.visibleFrame.maxY else { return false }
        return window.isVisible
            && !window.className.contains("StatusBarWindow")
            && !ShelfWindow.shared.isShelf(window)
            && window.frame.height > 100
            && window.frame.maxY > top - 40
    }
}
